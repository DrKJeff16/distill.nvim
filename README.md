# distill.nvim

Fold noisy logging, output, tracing, and control diagnostics without replacing
the rest of your folding setup.

## Features

<img width="1822" height="1095" alt="Screenshot 2026-06-22 at 10 46 41 AM" src="https://github.com/user-attachments/assets/c8148518-8c50-49c3-bbf5-2c659513a331" />

- Automatically closes configured folds when a supported file opens.
- Folds newly added matching statements on write without re-closing folds
  you manually opened.
- Preserves your existing `expr` folds for functions, classes, and blocks.
- Composes with Treesitter folds, LSP folds, and
  [nvim-origami](https://github.com/chrisgrieser/nvim-origami).
- Organizes logging, output, tracing, and control-flow diagnostics into
  language-specific subgroups and levels for Python, Go, JavaScript,
  TypeScript, Rust, C++, Zig, Ruby, Java, PHP, Swift, Lua, and Dart.
- Configures every group interactively through `:DistillConfig` or concisely in
  Lua, globally or per language.
- Lets you choose the minimum folded region size, so lone one-line calls can stay
  visible while adjacent logging blocks still fold.
- Supports custom languages and logging APIs with Lua patterns.
- Provides commands and a Lua API for folding, unfolding, toggling, refreshing,
  listing detections, enabling, and disabling.

## Installation

Requires Neovim 0.10+. Distill can start from Neovim's default manual folding,
or compose with an existing Treesitter or LSP fold expression without replacing
its function, class, and block folds. Deliberate `marker`, `indent`, `syntax`,
and `diff` folding methods are left untouched.

### With lazy.nvim

```lua
{
  "markosnarinian/distill.nvim",
  ft = {
    "python", "go", "javascript", "javascriptreact", "typescript",
    "typescriptreact", "rust", "cpp", "zig", "ruby", "java", "php",
    "swift", "lua", "dart",
  },
  cmd = {
    "DistillFold",
    "DistillUnfold",
    "DistillToggle",
    "DistillRefresh",
    "DistillList",
    "DistillConfig",
    "DistillEnable",
    "DistillDisable",
  },
  opts = {},
}
```

Add each configured language to `ft` so lazy.nvim loads the plugin for that
filetype. A Treesitter parser is recommended for accurate multi-line detection
(for example, install one with `:TSInstall rust`). Without a parser, Distill
falls back to a line-based heuristic for ordinary `callee(...)` calls.

## Usage

By default, configured folds are created and closed automatically when a
supported file opens. Newly matching statements are also folded when the file
is written. You can also control them manually:

| Command            | Action                                                   |
| ------------------ | -------------------------------------------------------- |
| `:DistillFold`      | Close configured folds in the current buffer.            |
| `:DistillUnfold`    | Open configured folds in the current buffer.             |
| `:DistillToggle`    | Toggle configured folds in the current buffer.           |
| `:DistillRefresh`   | Recompute folds after edits.                              |
| `:DistillList`      | List detected calls in the quickfix window.              |
| `:DistillConfig`    | Configure groups for the current language interactively. |
| `:DistillEnable`    | Re-enable and attach to open buffers.                    |
| `:DistillDisable`   | Disable and restore previous folding.                    |

### Interactive configuration

Run `:DistillConfig` (or press `<leader>dc`) in a supported buffer. The picker
navigates from family to subgroup to level:

```text
[on]    logging
[off]   output
[mixed] tracing
```

Select **Toggle all** at any depth to change that entire branch, or select one
level for a narrow override. Changes refresh visible supported buffers
immediately. **Reset language overrides** restores the global settings.

The picker uses `vim.ui.select`: Neovim provides a built-in selector, while UI
plugins such as Telescope, dressing.nvim, or snacks.nvim can render it as a
floating picker. Interactive choices last for the current Neovim session. Put
the equivalent `language_groups` values in your setup to persist them.

### Keybindings

Distill adds these normal-mode mappings by default:

| Mapping       | Action                         |
| ------------- | ------------------------------ |
| `<leader>df`  | Close configured folds.        |
| `<leader>du`  | Open configured folds.         |
| `<leader>dt`  | Toggle configured folds.       |
| `<leader>dr`  | Refresh configured folds.      |
| `<leader>dl`  | List detected statements.      |
| `<leader>dc`  | Configure this language.       |

Set `keymaps = false` to disable the defaults, or override individual mappings:

```lua
opts = {
  keymaps = {
    toggle = "<leader>l",
    list = false,
  },
}
```

Distill does not overwrite an existing mapping. Mappings installed by Distill
are removed by `:DistillDisable` and when `setup()` is called with new mappings.

## Configuration

Pass options through `opts` (or `require("distill").setup{}`). Defaults:

```lua
{
  enable = true,
  auto_fold = true,
  groups = {
    logging = true,
    output = false,
    tracing = false,
    control = false,
  },
  language_groups = {},
  min_lines = 2,
  base_foldexpr = nil,
  keymaps = {
    fold = "<leader>df",
    unfold = "<leader>du",
    toggle = "<leader>dt",
    refresh = "<leader>dr",
    list = "<leader>dl",
    config = "<leader>dc",
  },
  languages = {}, -- merged over the built-in specs below
}
```

- `enable` — Initial state. When `false`, action commands are no-ops and no
  mappings or folding hooks are activated; `:DistillEnable` remains available.
- `auto_fold` — Fold configured statements automatically when a supported file
  opens, and fold newly matching statements when the file is written. When
  `false`, folds are only created/closed via the commands or the API.
- `groups` — Global family defaults. Logging is folded by default; output,
  tracing, assertions, panics, and termination remain visible unless enabled.
  A table can override a subgroup or level while inheriting the family value:

  ```lua
  groups = {
    logging = { enabled = true, levels = { trace = false } },
    output = { enabled = false, print = true },
    tracing = false,
    control = false,
  }
  ```

- `language_groups` — Per-filetype overrides using the same compact shape. For
  example, `{ python = { output = { print = true, debugger = false } } }`.
  Interactive changes from `:DistillConfig` update this table for the current
  session.
- `min_lines` — Minimum number of lines a merged detected region must span.
  `2` skips lone one-line calls by default while still folding adjacent matches
  as a block. Set `1` to fold every match, including one-line calls; raise it to
  fold only larger blocks.
- `base_foldexpr` — The fold expression that produces your general folds. `nil`
  auto-detects native LSP and Treesitter expressions. An unknown custom
  expression is left untouched; set this option to its equivalent
  `function(lnum)` to compose it with Distill, e.g.
  `base_foldexpr = vim.lsp.foldexpr`.
- `keymaps` — Normal-mode mappings for the commands above. Set to `false` to
  disable all defaults, or set an individual action to `false` to disable it.
- `languages` — Per-filetype detection specs, deep-merged over the built-ins.
  Each spec defines Treesitter call node types and hierarchical group rules. See
  [Adding a language](#adding-a-language).

### What gets folded

Detection is chosen by the buffer's `filetype`. This is the complete built-in
catalog; individual entries appear as levels in `:DistillConfig`:

| Filetype | `logging` (default on) | `output` (default off) | `tracing` (default off) | `control` (default off) |
| --- | --- | --- | --- | --- |
| Python | debug/info/warning/error/critical/exception/success/generic logger methods | `print`, pprint, Rich output, warnings, traceback/faulthandler, breakpoint/pdb | — | process exit/abort calls |
| Go | trace/debug/info/warning/error/fatal, zerolog messages, stdlib/test logging | fmt/builtin print, spew dump, stack, breakpoint | — | `panic` |
| JavaScript / TypeScript | trace/debug/info/warning/error/verbose and known generic loggers | console print/table/dir, counters/assertions/warnings, process report | console timing, profiling, and groups | — |
| Rust | trace/debug/info/warn/error/log macros | stdout/stderr macros and `dbg!` | events and spans | panic/todo/unreachable and assert macros |
| C++ | level methods plus glog/Abseil, Qt, Boost, spdlog, ROS | C/C++/fmt print and standard/LLVM streams | trace events/ranges/profiling markers | check/assert macros and debugger traps |
| Zig | debug/info/warn/error | debug print and stack dumps | — | debug assertions |
| Ruby | debug/info/warn/error | Kernel print, pretty dump, caller stack, debugger gems | Datadog spans | raise/fail/abort/exit |
| Java | common levels, JUL flow, Android Log, Timber | system streams and stack traces | Sentry/Crashlytics capture | JUnit assertions and process termination |
| PHP | PSR-3 levels, generic log, error/syslog calls | formatted print, dumps, backtrace, Xdebug | Sentry capture | assertions |
| Swift | swift-log/os.Logger levels, NSLog/os_log/DDLog | print/debugPrint/dump and thread stack | signpost events and intervals | assertions, preconditions, fatal errors |
| Lua | common logger levels | print/io, Neovim dump/notify, traceback, debuggers | — | assert/error/exit |
| Dart | logging/logger levels and developer log | print, Flutter dumps/stack, developer debugger/inspect | Timeline events/spans | — |

The catalog intentionally excludes ordinary exceptions, returns, and production
side effects. Control constructs are opt-in because hiding an assertion, panic,
or termination call can obscure behavior rather than merely reduce noise.

Logging patterns match on the method name, so `logging.info(...)`,
`logger.debug(...)` and `self.logger.warning(...)` all fold, while setup calls
such as `logging.basicConfig(...)` and `logging.getLogger(...)` never do. Calls
with no arguments are ignored for Go, JavaScript/TypeScript, C++, Zig, and PHP,
so accessors like Go's `err.Error()` are not mistaken for log calls.

### Adding a language

Languages are keyed by Neovim filetype. A language spec contains:

- `call_node_types`: Treesitter node types that represent calls
- `groups`: `family → subgroup → level → rule`
- `patterns` on each rule: Lua patterns matched against the called function name
- `require_args` (optional, on the spec or a rule): ignore calls with an empty
  argument list
- `callee` (optional): `function(node, bufnr) -> string|nil` returning the callee
  text for grammars where a call is not a plain call node. Only needed for
  unusual shapes; the built-in extractor handles `function`, `macro`, `method`
  and `name` fields (see `lua/distill/callee.lua`, which also has the C++
  stream and Dart implementations).

```lua
opts = {
  languages = {
    go = {
      call_node_types = { "call_expression" },
      groups = {
        logging = {
          levels = {
            info = { patterns = { "%.Info$", "^log%.Print" } },
          },
        },
      },
    },
  },
}
```

Patterns match the callee text, not the full source line. For example,
`"%.Info$"` matches `log.Info(...)` and `logger.Info(...)`. Member accessors keep
their source separator (`.`, `::`, `->`), so use `"[%.:>]info$"` to match all
three.

Use `:InspectTree` to find the call node type for a language. Built-in specs are
deep-merged per key, so a custom level can be added without copying the catalog.
Its top-level family must also be enabled in `groups` or `language_groups`.

Rules match call-like syntax selected by `call_node_types`; they do not perform
arbitrary source-text search. The regex fallback likewise recognizes
`callee(...)` forms, so parser-specific macros, stream expressions, and
parenthesis-free calls require their Treesitter parser.

### Tests

```sh
nvim --headless -u NORC -c "luafile tests/run.lua"        # Python + folding behavior
nvim --headless -u NORC -c "luafile tests/languages.lua"  # every built-in language
nvim --headless -u NORC -c "luafile tests/lifecycle.lua"  # config + restore behavior
```

`tests/languages.lua` skips a language whose parser is not installed. Set
`DISTILL_PARSERS` to a directory of `<lang>.so` files to test parsers
outside your runtimepath.

Run `:checkhealth distill` to inspect the current buffer's language support,
parser availability, and folding compatibility.

## API

```lua
local fl = require("distill")

fl.setup(opts)    -- configure (lazy does this via `opts`)
fl.fold(bufnr)    -- close configured folds (bufnr optional, defaults to current)
fl.unfold(bufnr)  -- open configured folds
fl.toggle(bufnr)  -- toggle
fl.refresh(bufnr) -- recompute
fl.list(bufnr)    -- quickfix list of detections
fl.config(bufnr)  -- open the group picker
fl.detect(bufnr)  -- regions include group, subgroup, and level metadata
fl.enable()       -- re-enable at runtime
fl.disable()      -- disable and restore folding
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
