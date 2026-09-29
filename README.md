# distill.nvim

Automatically fold logging statements—and optionally debug-print calls—without
changing the rest of your folding setup.

## Features

<img width="1822" height="1095" alt="Screenshot 2026-06-22 at 10 46 41 AM" src="https://github.com/user-attachments/assets/c8148518-8c50-49c3-bbf5-2c659513a331" />

- Automatically closes logging folds when a supported file opens.
- Folds newly added logging statements on write without re-closing logging folds
  you manually opened.
- Preserves your existing `expr` folds for functions, classes, and blocks.
- Composes with Treesitter folds, LSP folds, and
  [nvim-origami](https://github.com/chrisgrieser/nvim-origami).
- Supports logging calls out of the box for Python, Go, JavaScript, TypeScript,
  Rust, C++, Zig, Ruby, Java, PHP, Swift, Lua, and Dart.
- Optionally folds plain debug-print calls such as Python's `print(...)`,
  JavaScript's `console.log(...)`, and Rust's `println!(...)`.
- Lets you choose the minimum folded region size, so lone one-line calls can stay
  visible while adjacent logging blocks still fold.
- Supports custom languages and logging APIs with Lua patterns.
- Provides commands and a Lua API for folding, unfolding, toggling, refreshing,
  listing detections, enabling, and disabling.

## Installation

Requires Neovim 0.10+ and `expr`-based folding, usually Treesitter or LSP. The
plugin composes logging folds on top of that base fold expression instead of
replacing it.

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
    "DistillEnable",
    "DistillDisable",
  },
  opts = {},
}
```

Add each configured language to `ft` so lazy.nvim loads the plugin for that
filetype. Each language also needs its Treesitter parser installed (for example
with `:TSInstall rust`); without one the plugin falls back to a line-based
heuristic that handles simple, single-call-per-line cases.

## Usage

By default, logging folds are created and closed automatically when a supported
file opens. New logging statements are also folded when the file is written. You
can also control them manually:

| Command      | Action                                      |
| ------------ | ------------------------------------------- |
| `:DistillFold`    | Close logging folds in the current buffer.  |
| `:DistillUnfold`  | Open logging folds in the current buffer.   |
| `:DistillToggle`  | Toggle logging folds in the current buffer. |
| `:DistillRefresh` | Recompute logging folds after edits.        |
| `:DistillList`    | List detected calls in the quickfix window. |
| `:DistillEnable`  | Re-enable and attach to open buffers.       |
| `:DistillDisable` | Disable and restore previous folding.       |

## Configuration

Pass options through `opts` (or `require("distill").setup{}`). Defaults:

```lua
{
  enable = true,
  auto_fold = true,
  fold_print = false,
  min_lines = 2,
  base_foldexpr = nil,
  languages = {}, -- merged over the built-in specs below
}
```

- `enable` — Master switch. When `false`, the plugin installs nothing and every
  command is a no-op.
- `auto_fold` — Fold logging statements automatically when a supported file
  opens, and fold newly added logging statements when the file is written. When
  `false`, folds are only created/closed via the commands or the API.
- `fold_print` — Also fold plain debug-print calls (Python's `print` / `pprint`,
  JavaScript's `console.log`, Rust's `println!`, ...).
  Logging-level calls fold regardless; this just adds the print family.
- `min_lines` — Minimum number of lines a (merged) logging region must span to be
  folded. `2` skips lone one-line calls by default while still folding adjacent
  logging calls as a block. Set `1` to fold everything that qualifies, including
  one-line calls; raise it to fold only larger blocks.
- `base_foldexpr` — The fold expression that produces your general folds. `nil`
  auto-detects (LSP when your foldexpr mentions `lsp`, otherwise Treesitter). Set
  to a `function(lnum)` to override, e.g. `base_foldexpr = vim.lsp.foldexpr`.
- `languages` — Per-filetype detection specs, deep-merged over the built-ins.
  Each spec defines Treesitter call node types, always-active logging patterns,
  and optional `print_patterns` used only when `fold_print = true`. See
  [Adding a language](#adding-a-language).
- `fold_print` and `min_lines` apply to every language.

### What gets folded

Detection is chosen by the buffer's `filetype`. Logging calls always fold; the
print-style calls in the last column only fold when `fold_print = true`.

| Filetype                                                      | Logging calls (always)                                                                                   | Print-style (`fold_print`)                    |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `python`                                                      | `.debug` `.info` `.warning` `.warn` `.error` `.critical` `.exception` `.fatal` `.log`                   | `print` `pprint`                              |
| `go`                                                          | `.Debug` `.Info` `.Warn` `.Error` `.Fatal` `.Panic` `.Trace` (+ `f` `ln` `w` `Context`), `.Msg`, `log.Print*` | `fmt.Print*` `fmt.Fprint*` `print` `println`  |
| `javascript` `javascriptreact` `typescript` `typescriptreact` | `.debug` `.info` `.warn` `.error` `.trace` `.fatal` (`console.*`, winston, pino, ...)                   | `console.log` `console.dir` `console.table`   |
| `rust`                                                        | `trace!` `debug!` `info!` `warn!` `error!` `log!` `event!`, also path-qualified (`log::info!`)          | `println!` `print!` `eprintln!` `eprint!` `dbg!` |
| `cpp`                                                         | `.info` etc. (spdlog), `LOG(...)` `DLOG` `VLOG`, `qDebug()` and other stream-style `<<` logging, `LOG_*` `SPDLOG_*` | `std::cout <<` `std::cerr <<` `printf` `std::println` |
| `zig`                                                         | `.debug` `.info` `.warn` `.err` (`std.log`, scoped loggers)                                              | `std.debug.print`                             |
| `ruby`                                                        | `.debug` `.info` `.warn` `.error` `.fatal` `.unknown`, `warn`                                            | `puts` `print` `p` `pp`                       |
| `java`                                                        | `.trace` `.debug` `.info` `.warn` `.error` `.fatal` `.severe` `.fine*`, Android `Log.d/i/w/e/v`, `Timber` | `System.out.print*` `System.err.print*` `.printStackTrace` |
| `php`                                                         | `->debug` `->info` `->warning` `->error` ... `Log::info`, `->log`, `error_log`                           | `var_dump` `print_r` `dump` `dd`              |
| `swift`                                                       | `.debug` `.info` `.notice` `.warning` `.error` `.fault` `.log`, `NSLog`, `os_log`, `DDLog*`             | `print` `debugPrint` `dump`                   |
| `lua`                                                         | `.debug` `.info` `.warn` `.error` `.trace` `.fatal` (`log.info`, `logger:debug`)                         | `print` `vim.print` `vim.notify`              |
| `dart`                                                        | `.debug` `.info` `.warning` `.severe` ..., `logger.d/i/w/e`, `developer.log`, `log`                      | `print` `debugPrint`                          |

Logging patterns match on the method name, so `logging.info(...)`,
`logger.debug(...)` and `self.logger.warning(...)` all fold, while setup calls
such as `logging.basicConfig(...)` and `logging.getLogger(...)` never do. Calls
with no arguments are ignored for Go, JavaScript/TypeScript, C++, Zig, and PHP,
so accessors like Go's `err.Error()` are not mistaken for log calls.

### Adding a language

Languages are keyed by Neovim filetype. A language spec contains:

- `call_node_types`: Treesitter node types that represent calls
- `patterns`: Lua patterns matched against the called function name
- `print_patterns` (optional): extra patterns folded only when `fold_print = true`
- `require_args` (optional): ignore calls with an empty argument list
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
      patterns = { "^fmt%.Print", "^log%.", "%.Debug$", "%.Info$" },
    },
  },
}
```

Patterns match the callee text, not the full source line. For example,
`"%.Info$"` matches `log.Info(...)` and `logger.Info(...)`. Member accessors keep
their source separator (`.`, `::`, `->`), so use `"[%.:>]info$"` to match all
three.

Use `:InspectTree` to find the call node type for a language. Built-in specs are
overridden per key, so `languages = { go = { patterns = { ... } } }` replaces
Go's built-in `patterns` list entirely.

### Tests

```sh
nvim --headless -u NORC -c "luafile tests/run.lua"        # Python + folding behavior
nvim --headless -u NORC -c "luafile tests/languages.lua"  # every built-in language
```

`tests/languages.lua` skips a language whose parser is not installed. Set
`DISTILL_PARSERS` to a directory of `<lang>.so` files to test parsers
outside your runtimepath.

## API

```lua
local fl = require("distill")

fl.setup(opts)    -- configure (lazy does this via `opts`)
fl.fold(bufnr)    -- close logging folds (bufnr optional, defaults to current)
fl.unfold(bufnr)  -- open logging folds
fl.toggle(bufnr)  -- toggle
fl.refresh(bufnr) -- recompute
fl.list(bufnr)    -- quickfix list of detections
fl.detect(bufnr)  -- -> { { start = <lnum>, ["end"] = <lnum>, text = <callee> }, ... }
fl.enable()       -- re-enable at runtime
fl.disable()      -- disable and restore folding
```

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
