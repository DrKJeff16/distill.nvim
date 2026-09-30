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
-- Optional spec fields beyond `call_node_types` / `groups`:
--   * `callee = function(node, bufnr) -> string|nil` overrides callee extraction
--     for grammars where a call is not a simple call node (see callee.lua).
--   * `require_args = true` ignores calls with an empty argument list, which
--     separates `logger.Error("x")` from accessors like `err.Error()`.

local callee = require("distill.callee")

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

local function rule(patterns, opts)
  return vim.tbl_extend("force", { patterns = patterns }, opts or {})
end

local python = {
  call_node_types = { "call" },
  groups = {
    logging = {
      levels = {
        debug = rule({ "%.debug$" }),
        info = rule({ "%.info$" }),
        warning = rule({ "%.warning$", "%.warn$" }),
        error = rule({ "%.error$" }),
        critical = rule({ "%.critical$", "%.fatal$" }),
        exception = rule({ "%.exception$" }),
        success = rule({ "%.success$" }),
        generic = rule({ "%.log$" }),
      },
    },
    output = {
      print = {
        builtin = rule({ "^print$" }),
        pretty = rule({ "^pprint$", "^pp$", "^pprint%.pprint$", "^pprint%.pp$" }),
        rich = rule({ "^rich%.print$", "^rich%.print_json$" }),
      },
      warning = { warnings = rule({ "^warnings%.warn$" }, { priority = 100 }) },
      stack = {
        traceback = rule({ "^traceback%.print_" }),
        faulthandler = rule({ "^faulthandler%.dump_traceback", "^faulthandler%.dump_traceback_later$" }),
      },
      debugger = {
        breakpoint_ = rule({ "^breakpoint$" }, { require_args = false }),
        pdb = rule({ "^pdb%.set_trace$", "^pdb%.post_mortem$", "^pdb%.pm$" }, { require_args = false }),
      },
    },
    control = {
      termination = {
        exit = rule({ "^sys%.exit$", "^os%._exit$", "^os%.abort$" }, { require_args = false }),
      },
    },
  },
}

local go_suffixes = { "", "f", "ln", "w", "Context", "Ctx" }
local go = {
  call_node_types = { "call_expression" },
  require_args = true,
  groups = {
    logging = {
      levels = {
        trace = rule(members(with_suffixes({ "Trace" }, go_suffixes))),
        debug = rule(members(with_suffixes({ "Debug", "DPanic" }, go_suffixes))),
        info = rule(members(with_suffixes({ "Info" }, go_suffixes))),
        warning = rule(members(with_suffixes({ "Warn", "Warning" }, go_suffixes))),
        error = rule(members(with_suffixes({ "Error" }, go_suffixes))),
        fatal = rule(members(with_suffixes({ "Fatal", "Panic" }, go_suffixes))),
        message = rule(members({ "Msg", "Msgf", "Send" })),
        generic = rule(join(members({ "Log", "Logf", "LogAttrs", "Output" }), { "^t%.Log", "^log%.Print" })),
      },
    },
    output = {
      print = { fmt = rule({ "^fmt%.Print", "^fmt%.Fprint", "^print$", "^println$" }) },
      dump = { spew = rule({ "^spew%.Dump$", "^spew%.Fdump$" }) },
      stack = {
        runtime = rule({ "^debug%.PrintStack$", "^runtime/debug%.PrintStack$" }, { require_args = false }),
      },
      debugger = { runtime = rule({ "^runtime%.Breakpoint$" }, { require_args = false }) },
    },
    control = { panic = { builtin = rule({ "^panic$" }) } },
  },
}

local javascript = {
  call_node_types = { "call_expression" },
  require_args = true,
  groups = {
    logging = {
      levels = {
        trace = rule(members({ "trace" })),
        debug = rule(members({ "debug" })),
        info = rule(members({ "info" })),
        warning = rule(members({ "warn", "warning" })),
        error = rule(members({ "error", "fatal" })),
        verbose = rule(members({ "verbose", "success" })),
        generic = rule({ "^Logger%.log$", "^logger%.log$" }),
      },
    },
    output = {
      print = {
        console = rule(
          { "^console%.log$", "^console%.dir$", "^console%.table$", "^console%.dirxml$" },
          { require_args = false }
        ),
      },
      diagnostic = {
        console = rule(
          { "^console%.assert$", "^console%.count$", "^console%.countReset$", "^process%.emitWarning$" },
          { require_args = false }
        ),
      },
      report = { process = rule({ "^process%.report%.writeReport$" }, { require_args = false }) },
    },
    tracing = {
      timing = {
        console = rule({ "^console%.time$", "^console%.timeLog$", "^console%.timeEnd$" }, { require_args = false }),
      },
      profiling = {
        console = rule(
          { "^console%.profile$", "^console%.profileEnd$", "^console%.timeStamp$" },
          { require_args = false }
        ),
      },
      groups = {
        console = rule(
          { "^console%.group$", "^console%.groupCollapsed$", "^console%.groupEnd$" },
          { require_args = false }
        ),
      },
    },
  },
}

local rust = {
  call_node_types = { "macro_invocation" },
  groups = {
    logging = {
      levels = {
        trace = rule(join(bare({ "trace" }), members({ "trace" }))),
        debug = rule(join(bare({ "debug" }), members({ "debug" }))),
        info = rule(join(bare({ "info" }), members({ "info" }))),
        warning = rule(join(bare({ "warn" }), members({ "warn" }))),
        error = rule(join(bare({ "error", "crit" }), members({ "error", "crit" }))),
        generic = rule(join(bare({ "log" }), members({ "log" }))),
      },
    },
    output = {
      print = {
        std = rule(
          join(
            bare({ "println", "print", "eprintln", "eprint" }),
            members({ "println", "print", "eprintln", "eprint" })
          )
        ),
      },
      dump = { debug = rule(join(bare({ "dbg" }), members({ "dbg" }))) },
    },
    tracing = {
      events = { event = rule(join(bare({ "event" }), members({ "event" }))) },
      spans = {
        span = rule(
          join(
            bare({ "span", "trace_span", "debug_span", "info_span", "warn_span", "error_span" }),
            members({ "span", "trace_span", "debug_span", "info_span", "warn_span", "error_span" })
          )
        ),
      },
    },
    control = {
      panic = { panic = rule(join(bare({ "panic", "todo", "unimplemented", "unreachable" }), members({ "panic" }))) },
      assert = {
        assert = rule(
          join(
            bare({ "assert", "assert_eq", "assert_ne", "debug_assert", "debug_assert_eq", "debug_assert_ne" }),
            members({ "assert" })
          )
        ),
      },
    },
  },
}

local cpp = {
  call_node_types = { "call_expression", "binary_expression" },
  callee = callee.cpp,
  require_args = true,
  groups = {
    logging = {
      levels = {
        trace = rule(members({ "trace" })),
        debug = rule(members({ "debug" })),
        info = rule(members({ "info", "notice" })),
        warning = rule(members({ "warn", "warning" })),
        error = rule(members({ "error", "critical", "fatal" })),
      },
      macros = {
        glog = rule(
          join(bare({ "LOG", "DLOG", "VLOG", "PLOG", "RAW_LOG" }), { "^[PDV]?LOG_[%u_]+$", "^ABSL_[PDV]?LOG" })
        ),
        qt = rule(bare({
          "qDebug",
          "qInfo",
          "qWarning",
          "qCritical",
          "qFatal",
          "qCDebug",
          "qCInfo",
          "qCWarning",
          "qCCritical",
          "qErrnoWarning",
        })),
        boost = rule({ "^BOOST_LOG" }),
        spdlog = rule({ "^SPDLOG_[%u_]+$" }),
        ros = rule({ "^RCLCPP_[%u_]+$", "^ROS_[%u_]+$", "^CONSOLE_BRIDGE_log" }),
      },
    },
    output = {
      print = {
        c = rule(bare({ "printf", "fprintf", "vprintf", "vfprintf", "puts", "fputs", "putchar", "fputc", "perror" })),
        cpp = rule(bare({
          "std::printf",
          "std::fprintf",
          "std::puts",
          "std::print",
          "std::println",
          "fmt::print",
          "fmt::println",
        })),
      },
      stream = {
        std = rule(bare({
          "cout",
          "cerr",
          "clog",
          "std::cout",
          "std::cerr",
          "std::clog",
          "llvm::outs",
          "llvm::errs",
          "llvm::dbgs",
        })),
      },
    },
    tracing = {
      events = { trace = rule({ "^TRACE_EVENT", "^TRACE_COUNTER", "^TracyMessage", "^nvtxMark", "^__itt_marker$" }) },
      spans = { ranges = rule({ "^Zone", "^nvtxRange", "^__itt_task_" }) },
      profiling = { frame = rule({ "^FrameMark", "^TracyPlot" }) },
    },
    control = {
      assert = { checks = rule({ "^[DQPA]?CHECK", "^ABSL_[DQPA]?CHECK", "^Q_ASSERT", "^Q_CHECK_PTR$", "^RAW_CHECK$" }) },
      debugger = {
        trap = rule(
          bare({ "__debugbreak", "DebugBreak", "__builtin_debugtrap", "__builtin_trap" }),
          { require_args = false }
        ),
      },
    },
  },
}

local zig = {
  call_node_types = { "call_expression" },
  require_args = true,
  groups = {
    logging = {
      levels = {
        debug = rule(members({ "debug" })),
        info = rule(members({ "info" })),
        warning = rule(members({ "warn" })),
        error = rule(members({ "err" })),
      },
    },
    output = {
      print = { debug = rule({ "^std%.debug%.print$", "^debug%.print$" }) },
      stack = {
        debug = rule({
          "^std%.debug%.dumpCurrentStackTrace$",
          "^std%.debug%.dumpStackTrace$",
          "^std%.debug%.writeCurrentStackTrace$",
        }),
      },
    },
    control = { assert = { debug = rule({ "^std%.debug%.assert$" }) } },
  },
}

local ruby = {
  call_node_types = { "call" },
  groups = {
    logging = {
      levels = {
        debug = rule(members({ "debug" })),
        info = rule(members({ "info" })),
        warning = rule(join(members({ "warn" }), bare({ "warn" }))),
        error = rule(members({ "error", "fatal", "unknown" })),
      },
    },
    output = {
      print = { kernel = rule(bare({ "puts", "print", "printf", "putc", "display" })) },
      dump = { pretty = rule(bare({ "p", "pp" })) },
      stack = { caller = rule(bare({ "caller", "caller_locations" }), { require_args = false }) },
      debugger = {
        gems = rule(
          { "^binding%.break$", "^binding%.b$", "^binding%.pry$", "^debugger$", "^byebug$" },
          { require_args = false }
        ),
      },
    },
    tracing = { spans = { datadog = rule({ "^Datadog::Tracing%.trace$" }) } },
    control = {
      panic = { kernel = rule(bare({ "raise", "fail", "abort", "exit", "exit!" }), { require_args = false }) },
    },
  },
}

local java = {
  call_node_types = { "method_invocation" },
  groups = {
    logging = {
      levels = {
        trace = rule(members({ "trace" })),
        debug = rule(members({ "debug", "fine", "finer", "finest" })),
        info = rule(members({ "info", "config" })),
        warning = rule(members({ "warn", "warning" })),
        error = rule(members({ "error", "fatal", "severe" })),
      },
      android = {
        log = rule({ "^Log%.[divwe]$", "^Log%.wtf$", "^Log%.println$" }),
        timber = rule({
          "^Timber%.[divwe]$",
          "^Timber%.wtf$",
          "^Timber%.log$",
          "^Timber%..*%)%.[divwe]$",
          "^Timber%..*%)%.wtf$",
          "^Timber%..*%)%.log$",
        }),
      },
      structured = { flow = rule(members({ "traceEntry", "traceExit", "catching", "throwing", "always" })) },
    },
    output = {
      print = { system = rule({ "^System%.out%.print", "^System%.err%.print", "^System%.console%(%)[%.:]printf" }) },
      stack = { throwable = rule({ "%.printStackTrace$", "^Thread%.dumpStack$" }, { require_args = false }) },
    },
    tracing = {
      events = { otel = rule({ "^Sentry%.capture", "^FirebaseCrashlytics%..*recordException$" }) },
    },
    control = {
      assert = { junit = rule({ "^Assertions%.assert", "^Assert%.assert", "^Assertions%.fail$", "^Assert%.fail$" }) },
      termination = { system = rule({ "^System%.exit$", "^Runtime%..*halt$" }) },
    },
  },
}

local php = {
  call_node_types = { "function_call_expression", "member_call_expression", "scoped_call_expression" },
  require_args = true,
  groups = {
    logging = {
      levels = {
        debug = rule(members({ "debug" })),
        info = rule(members({ "info", "notice" })),
        warning = rule(members({ "warning", "warn" })),
        error = rule(members({ "error", "critical", "alert", "emergency" })),
        generic = rule({ "%->log$", "^Log::log$", "^error_log$", "^syslog$", "^trigger_error$", "^user_error$" }),
      },
    },
    output = {
      print = { formatted = rule(bare({ "printf", "vprintf" })) },
      dump = { native = rule(bare({ "var_dump", "print_r", "var_export", "dump", "dd" })) },
      stack = { native = rule(bare({ "debug_print_backtrace" }), { require_args = false }) },
      debugger = {
        xdebug = rule(bare({ "xdebug_break", "xdebug_debug_zval", "xdebug_var_dump" }), { require_args = false }),
      },
    },
    tracing = { events = { sentry = rule({ "^Sentry.*captureMessage$", "^Sentry.*captureException$" }) } },
    control = { assert = { native = rule(bare({ "assert" })) } },
  },
}

local swift = {
  call_node_types = { "call_expression" },
  groups = {
    logging = {
      levels = {
        trace = rule(members({ "trace" })),
        debug = rule(members({ "debug" })),
        info = rule(members({ "info", "notice" })),
        warning = rule(members({ "warning", "warn" })),
        error = rule(members({ "error", "fault", "critical" })),
        verbose = rule(members({ "verbose" })),
        generic = rule(join(
          members({ "log" }),
          bare({
            "NSLog",
            "os_log",
            "os_log_with_type",
            "os_log_info",
            "os_log_debug",
            "os_log_error",
            "os_log_fault",
          }),
          { "^DDLog%a+$" }
        )),
      },
    },
    output = {
      print = { std = rule(bare({ "print", "debugPrint" })) },
      dump = { std = rule(bare({ "dump" })) },
      stack = {
        thread = rule({ "^Thread%.callStackSymbols$", "^Thread%.callStackReturnAddresses$" }, { require_args = false }),
      },
    },
    tracing = {
      events = { signpost = rule(bare({ "os_signpost", "os_signpost_event_emit" })) },
      spans = { signpost = rule(bare({ "os_signpost_interval_begin", "os_signpost_interval_end" })) },
    },
    control = {
      assert = {
        swift = rule(
          bare({ "assert", "assertionFailure", "precondition", "preconditionFailure" }),
          { require_args = false }
        ),
      },
      panic = { swift = rule(bare({ "fatalError" })) },
    },
  },
}

local lua = {
  call_node_types = { "function_call" },
  groups = {
    logging = {
      levels = {
        trace = rule(members({ "trace" })),
        debug = rule(members({ "debug" })),
        info = rule(members({ "info", "notice" })),
        warning = rule(members({ "warn", "warning" })),
        error = rule(members({ "error", "fatal", "critical" })),
      },
    },
    output = {
      print = { lua = rule({ "^print$", "^io%.write$", "^io%.stderr:write$", "^io%.stdout:write$" }) },
      dump = { nvim = rule({ "^vim%.print$", "^vim%.pretty_print$" }) },
      notify = {
        nvim = rule({
          "^vim%.notify$",
          "^vim%.notify_once$",
          "^vim%.deprecate$",
          "^vim%.api%.nvim_echo$",
          "^vim%.api%.nvim_err_writeln$",
          "^vim%.api%.nvim_out_write$",
          "^vim%.api%.nvim_err_write$",
        }),
      },
      stack = { debug = rule({ "^debug%.traceback$" }, { require_args = false }) },
      debugger = {
        lua = rule({ "^debug%.debug$", "^mobdebug%.pause$", "^mobdebug%.start$" }, { require_args = false }),
      },
    },
    control = {
      assert = { lua = rule(bare({ "assert" })) },
      panic = { lua = rule(join(bare({ "error" }), { "^os%.exit$" }), { require_args = false }) },
    },
  },
}

local dart = {
  call_node_types = { "expression_statement" },
  callee = callee.dart,
  groups = {
    logging = {
      levels = {
        trace = rule(join(members({ "trace" }), { "[lL]og[%w_]*%.[tv]$" })),
        debug = rule(join(members({ "debug", "fine", "finer", "finest" }), { "[lL]og[%w_]*%.d$" })),
        info = rule(join(members({ "info", "config" }), { "[lL]og[%w_]*%.i$" })),
        warning = rule(join(members({ "warn", "warning" }), { "[lL]og[%w_]*%.w$" })),
        error = rule(join(members({ "error", "fatal", "severe", "shout" }), { "[lL]og[%w_]*%.[ef]$" })),
        verbose = rule(members({ "verbose" })),
        generic = rule(join({ "%.log$" }, bare({ "log" }))),
      },
    },
    output = {
      print = { dart = rule(bare({ "print", "debugPrint" })) },
      stack = { flutter = rule(bare({ "debugPrintStack" })) },
      dump = {
        flutter = rule(bare({
          "debugDumpApp",
          "debugDumpRenderTree",
          "debugDumpLayerTree",
          "debugDumpSemanticsTree",
          "debugDumpFocusTree",
          "debugDumpMouseTracker",
        })),
      },
      debugger = { developer = rule(members({ "debugger", "inspect", "postEvent" }), { require_args = false }) },
    },
    tracing = {
      events = { timeline = rule({ "^Timeline%.instantSync$", "^TimelineTask%.instant$" }) },
      spans = {
        timeline = rule({
          "^Timeline%.startSync$",
          "^Timeline%.finishSync$",
          "^Timeline%.timeSync$",
          "^TimelineTask%.start$",
          "^TimelineTask%.finish$",
        }, { require_args = false }),
      },
    },
  },
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
