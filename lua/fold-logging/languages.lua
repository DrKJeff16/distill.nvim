-- Built-in language specifications.
--
-- A spec is keyed by `filetype` and describes how to recognise logging /
-- debug-print calls in that language. Two detection backends use the same spec:
--
--   * Treesitter (preferred): every node whose type is in `call_node_types`
--     is inspected, the *callee* text is extracted (e.g. "logger.info",
--     "print") and tested against `patterns`.
--   * Regex fallback (no parser): each line is scanned for `callee(` shapes and
--     the captured callee is tested against the same `patterns`.
--
-- `patterns` are plain Lua patterns matched with `string.find` (unanchored
-- unless you anchor them yourself). They are tested against the callee text, so
-- `"%.info$"` matches `logging.info` / `logger.info` / `self.logger.info`.
--
-- Optional spec fields beyond `call_node_types` / `patterns` / `print_patterns`:
--   * `callee = function(node, bufnr) -> string|nil` overrides callee extraction
--     for grammars where a call is not a simple call node (see callee.lua).
--   * `require_args = true` ignores calls with an empty argument list, which
--     separates `logger.Error("x")` from accessors like `err.Error()`.

local callee = require("fold-logging.callee")

local M = {}

-- Pattern builders. A "member" pattern matches a callee ending in `<sep><name>`
-- where sep is `.`, `::` or `->`, so one list covers `logger.info`,
-- `spdlog::info`, `$this->logger->info` and `log::info`.
local function members(names)
  local out = {}
  for _, n in ipairs(names) do
    out[#out + 1] = "[%.:>]" .. n .. "$"
  end
  return out
end

-- A "bare" pattern matches a callee that is exactly `<name>` (`print`, `info`).
local function bare(names)
  local out = {}
  for _, n in ipairs(names) do
    out[#out + 1] = "^" .. n .. "$"
  end
  return out
end

-- Concatenate pattern lists.
local function join(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end

-- Every `<name><suffix>` combination, e.g. Info, Infof, Infow, ...
local function with_suffixes(names, suffixes)
  local out = {}
  for _, n in ipairs(names) do
    for _, sfx in ipairs(suffixes) do
      out[#out + 1] = n .. sfx
    end
  end
  return out
end

-- `patterns` are always active. `print_patterns` are only used when the
-- `fold_print` option is enabled.
--
-- The log-level patterns match on the method name (anchored to the end of the
-- callee), so `logging.info(...)`, `logger.debug(...)`, `self.logger.warning(...)`,
-- `log.error(...)`, ... fold, while setup calls like `logging.basicConfig(...)`
-- / `logging.getLogger(...)` are deliberately left alone.
local python = {
  call_node_types = { "call" },
  patterns = {
    "%.debug$",
    "%.info$",
    "%.warning$",
    "%.warn$",
    "%.error$",
    "%.critical$",
    "%.exception$",
    "%.fatal$",
    "%.log$", -- logging.log(level, ...)
  },
  print_patterns = {
    "^print$", -- print(...)
    "^pprint$", -- pprint(...)
  },
}

-- Go: stdlib `log`, slog, zap, logrus, zerolog. `require_args` keeps
-- `err.Error()` from counting as a log call.
local go = {
  call_node_types = { "call_expression" },
  require_args = true,
  patterns = join(
    members(with_suffixes(
      { "Debug", "Info", "Warn", "Warning", "Error", "Fatal", "Panic", "Trace" },
      { "", "f", "ln", "w", "Context", "Ctx" }
    )),
    members({ "Msg", "Msgf", "Logf", "LogAttrs" }), -- zerolog / testing / slog
    { "^t%.Log$", "^log%.Print" } -- t.Log, log.Print / Printf / Println
  ),
  print_patterns = { "^fmt%.Print", "^fmt%.Fprint", "^print$", "^println$" },
}

-- JavaScript / TypeScript: `console.*` and logger objects (winston, pino,
-- bunyan, loglevel, ...). `console.log` is the print-style call, so it is only
-- folded with `fold_print`; a bare `.log` pattern would also hit `Math.log`.
local javascript = {
  call_node_types = { "call_expression" },
  require_args = true,
  patterns = members({ "debug", "info", "warn", "warning", "error", "trace", "fatal" }),
  print_patterns = { "^console%.log$", "^console%.dir$", "^console%.table$" },
}

-- Rust: `log` / `tracing` / `defmt` macros. Macro invocations have no call
-- node, and the callee text is the macro path without the `!` (`info`,
-- `log::info`, `tracing::debug`).
local rust = {
  call_node_types = { "macro_invocation" },
  patterns = join(
    bare({ "trace", "debug", "info", "warn", "error", "log", "event" }),
    members({ "trace", "debug", "info", "warn", "error", "log", "event" })
  ),
  print_patterns = bare({ "println", "print", "eprintln", "eprint", "dbg" }),
}

-- C++: spdlog / glog / Qt / Boost.Log / ROS macros and methods, plus
-- stream-style logging (`LOG(INFO) << ...`, `qDebug() << ...`).
local cpp = {
  call_node_types = { "call_expression", "binary_expression" },
  callee = callee.cpp,
  require_args = true,
  patterns = join(
    members({ "trace", "debug", "info", "notice", "warn", "warning", "error", "critical", "fatal" }),
    bare({ "LOG", "DLOG", "VLOG", "PLOG", "qDebug", "qInfo", "qWarning", "qCritical", "qFatal" }),
    bare({ "BOOST_LOG_TRIVIAL", "BOOST_LOG" }),
    { "^D?LOG_[%u_]+$", "^SPDLOG_[%u_]+$", "^RCLCPP_[%u_]+$", "^ROS_[%u_]+$" }
  ),
  print_patterns = join(
    bare({ "printf", "fprintf", "puts", "perror", "cout", "cerr", "clog" }),
    bare({ "std::printf", "std::puts", "std::print", "std::println", "fmt::print", "fmt::println" }),
    bare({ "std::cout", "std::cerr", "std::clog" })
  ),
}

-- Zig: `std.log` (and scoped loggers) plus `std.debug.print`.
local zig = {
  call_node_types = { "call_expression" },
  require_args = true,
  patterns = members({ "debug", "info", "warn", "err" }),
  print_patterns = { "^std%.debug%.print$", "^debug%.print$" },
}

-- Ruby: Logger / Rails.logger and Kernel#warn. Calls may omit parentheses
-- (`logger.info "x"`), which Treesitter still parses as a `call`.
local ruby = {
  call_node_types = { "call" },
  patterns = join(members({ "debug", "info", "warn", "error", "fatal", "unknown" }), bare({ "warn" })),
  print_patterns = bare({ "puts", "print", "p", "pp" }),
}

-- Java: SLF4J / Log4j / java.util.logging / Android `Log` / Timber. Method
-- invocations keep the receiver in a separate field; callee.default rebuilds
-- the `System.out.println` / `logger.info` text.
local java = {
  call_node_types = { "method_invocation" },
  patterns = join(
    members({ "trace", "debug", "info", "warn", "warning", "error", "fatal", "severe", "fine", "finer", "finest" }),
    { "^Log%.[divwe]$", "^Log%.wtf$", "^Timber%.[divwe]$", "^Timber%..*%)%.[divwe]$" }
  ),
  print_patterns = { "^System%.out%.print", "^System%.err%.print", "%.printStackTrace$" },
}

-- PHP: PSR-3 / Monolog / Laravel `Log::` and `error_log`. Method (`->`) and
-- static (`::`) calls are separate node types from plain function calls.
local php = {
  call_node_types = { "function_call_expression", "member_call_expression", "scoped_call_expression" },
  require_args = true,
  patterns = join(
    members({ "debug", "info", "notice", "warning", "warn", "error", "critical", "alert", "emergency" }),
    { "%->log$" },
    bare({ "error_log" })
  ),
  print_patterns = bare({ "var_dump", "print_r", "dump", "dd" }),
}

-- Swift: os.Logger / swift-log / NSLog / os_log / CocoaLumberjack.
local swift = {
  call_node_types = { "call_expression" },
  patterns = join(
    members({ "trace", "debug", "info", "notice", "warning", "warn", "error", "fault", "critical", "log" }),
    bare({ "NSLog", "os_log" }),
    { "^DDLog%a+$" }
  ),
  print_patterns = bare({ "print", "debugPrint", "dump" }),
}

-- Lua: logger objects (`log.debug(...)`, `logger:info(...)`). Print-style
-- calls include Neovim's `vim.notify` / `vim.print`.
local lua = {
  call_node_types = { "function_call" },
  patterns = members({ "trace", "debug", "info", "warn", "error", "fatal" }),
  print_patterns = { "^print$", "^vim%.print$", "^vim%.notify$", "^vim%.notify_once$" },
}

-- Dart: `print` / `debugPrint`, dart:developer `log`, and the `logger` /
-- `logging` packages. Dart has no call node, so statements are inspected and
-- callee.dart pulls the callee out of the statement's selectors. Single-letter
-- methods (`logger.d`, `_log.e`) must hang off something named like a logger.
local dart = {
  call_node_types = { "expression_statement" },
  callee = callee.dart,
  patterns = join(
    members({ "trace", "debug", "info", "warn", "warning", "error", "fatal", "severe", "shout", "fine", "finer", "finest", "verbose" }),
    { "[lL]og[%w_]*%.[dtiwefv]$", "%.log$" },
    bare({ "log" })
  ),
  print_patterns = bare({ "print", "debugPrint", "debugPrintStack" }),
}

M.defaults = {
  python = python,
  go = go,
  javascript = javascript,
  javascriptreact = javascript,
  typescript = javascript,
  typescriptreact = javascript,
  rust = rust,
  cpp = cpp,
  zig = zig,
  ruby = ruby,
  java = java,
  php = php,
  swift = swift,
  lua = lua,
  dart = dart,
}

return M
