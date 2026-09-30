# distill.nvim

Fold logging and debug calls in Neovim while preserving your function, class,
and block folds.

<img width="1822" height="1095" alt="Distill folding diagnostic calls in Neovim" src="https://github.com/user-attachments/assets/c8148518-8c50-49c3-bbf5-2c659513a331" />

Distill finds logging, output, tracing, and control calls, then adds them to your
existing Neovim folds. It supports Python, Go, JavaScript, TypeScript, Rust,
C++, Zig, Ruby, Java, PHP, Swift, Lua, and Dart out of the box.

- Keeps function, class, and block folds from Treesitter, LSP, or
  [nvim-origami](https://github.com/chrisgrieser/nvim-origami).
- Closes matching diagnostic blocks when a file opens and folds new matches on
  write without re-closing folds you opened manually.
- Groups detections by family, subgroup, and level, with global and per-language
  controls.
- Provides an interactive picker, commands, keymaps, and a Lua API.
- Supports custom languages and diagnostic APIs with Lua patterns.

## Requirements and installation

Distill requires Neovim 0.10+. A Treesitter parser is recommended for accurate
multi-line and language-specific detection. Without one, Distill falls back to
a line-based heuristic for ordinary `callee(...)` calls.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "markosnarinian/distill.nvim",
  ft = {
    "python", "go", "javascript", "javascriptreact", "typescript",
    "typescriptreact", "rust", "cpp", "zig", "ruby", "java", "php",
    "swift", "lua", "dart",
  },
  cmd = {
    "DistillFold", "DistillUnfold", "DistillToggle", "DistillRefresh",
    "DistillList", "DistillConfig", "DistillEnable", "DistillDisable",
  },
  opts = {},
}
```

Include every language you use in `ft` so lazy.nvim loads Distill for that
filetype. Install its parser for full detection, for example with
`:TSInstall rust`.

No folding plugin is required. Distill works with Neovim's default `manual`
folding and composes with recognized Treesitter and LSP fold expressions. It
does not attach to `marker`, `indent`, `syntax`, or `diff` folding. Other fold
expressions require an explicit `base_foldexpr` function. An empty manual-fold
window is supported; a window that already contains manual folds is left
untouched so Distill cannot destroy them.

## Quick start

Logging folds are enabled by default. Output, tracing, and control diagnostics
remain visible until you opt in. A detected region must span at least two lines,
so isolated one-line calls stay open while adjacent calls fold together.

Open a supported file and use:

| Command | Default mapping | Action |
| --- | --- | --- |
| `:DistillFold` | `<leader>df` | Close configured folds. |
| `:DistillUnfold` | `<leader>du` | Open configured folds. |
| `:DistillToggle` | `<leader>dt` | Toggle configured folds. |
| `:DistillRefresh` | `<leader>dr` | Recompute folds after edits. |
| `:DistillList` | `<leader>dl` | List detected calls in quickfix. |
| `:DistillConfig` | `<leader>dc` | Configure the current language. |
| `:DistillEnable` | — | Re-enable Distill and attach open buffers. |
| `:DistillDisable` | — | Disable Distill and restore previous folding. |

Set `keymaps = false` to disable all default mappings, or set an individual
action to `false` to leave it unmapped. Distill never replaces an existing
mapping and removes only mappings it installed.

Run `:checkhealth distill` to inspect language support, parser availability,
and visible-window folding compatibility for every loaded supported buffer.

### Interactive configuration

Run `:DistillConfig` in a supported buffer. The picker drills from family to
subgroup to level and shows each branch as `on`, `off`, or `mixed`. For example:

```text
[on]    logging
[off]   output
[mixed] tracing
```

Open a family or subgroup and select **Toggle all** to change that branch, or
select an individual level to toggle only that rule. Changes refresh visible
supported buffers immediately. **Reset language overrides** restores the global
settings for the current language.

The picker uses `vim.ui.select`: Neovim's built-in selector works, and any
configured replacement supplies its interface. Picker changes last for the
current Neovim session; reproduce the equivalent settings in `language_groups`
to persist them.

## Configuration

Pass only the settings you want to change through lazy.nvim's `opts` or
`require("distill").setup()`. For example, this also folds output calls:

```lua
opts = {
  groups = { output = true },
}
```

The default settings are shown below, with the built-in language specs elided:

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

  languages = {}, -- custom overrides; built-in specs omitted
}
```

Group settings accept booleans or nested overrides. This folds logging except
its `trace` level, folds output, and leaves debugger calls visible in Python:

```lua
opts = {
  groups = {
    logging = { enabled = true, levels = { trace = false } },
    output = true,
    tracing = false,
    control = false,
  },
  language_groups = {
    python = {
      output = { debugger = false },
    },
  },
}
```

Within a table, `enabled` supplies the fallback value and more specific entries
override it. Per-filetype settings take precedence over global settings.

| Option | Purpose |
| --- | --- |
| `enable` | Initial state. When false, folding hooks and mappings remain inactive; `:DistillEnable` is still available. |
| `auto_fold` | Fold on file open and fold new matches on write. When false, use commands or the API. |
| `groups` | Global family, subgroup, and level settings. |
| `language_groups` | Per-filetype overrides using the same compact shape as `groups`. |
| `min_lines` | Minimum merged region length. Use `1` to fold isolated one-line calls. |
| `base_foldexpr` | General fold expression to compose with. `nil` detects native LSP and Treesitter expressions. |
| `keymaps` | Default normal-mode mappings. Use `false` globally or for one action. |
| `languages` | Detection specs deep-merged over the built-in languages. |

`base_foldexpr` must be a `function(lnum) -> foldexpr value`. Distill calls it
for general folds and layers configured diagnostic folds on top.

## Language catalog

Detection follows the buffer's `filetype`. The table summarizes every built-in
language. Use `:DistillConfig` to browse its exact family, subgroup, and level
names.

| Filetype | `logging` (on) | `output` (off) | `tracing` (off) | `control` (off) |
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

Detection matches call syntax and callee names, not program semantics. Control
rules are opt-in because hiding assertions, exception-raising calls, panics, or
termination can obscure important behavior.

Logging patterns match the method name, so `logging.info(...)`,
`logger.debug(...)`, and `self.logger.warning(...)` all fold. Setup calls such
as `logging.basicConfig(...)` and `logging.getLogger(...)` do not. Go,
JavaScript/TypeScript, C++, Zig, and PHP reject empty calls by default, so
accessors such as Go's `err.Error()` are not mistaken for logs. Rules for APIs
that are meaningful without arguments, such as `console.timeEnd()`, override
that language default.

## Adding a language or API

Language specs use Neovim filetypes and a
`family → subgroup → level → rule` hierarchy:

```lua
opts = {
  languages = {
    go = {
      groups = {
        logging = {
          levels = {
            audit = { patterns = { "^audit%.Record$" } },
          },
        },
      },
    },
  },
}
```

Spec fields include:

- `call_node_types`: Treesitter nodes representing calls.
- `groups`: the hierarchical detection rules.
- `require_args`: optional rejection of empty calls for the whole language.
- `callee`: optional `function(node, bufnr) -> string|nil` extractor for unusual
  grammar shapes. The built-in extractor already handles `function`, `macro`,
  `method`, and `name` fields.

Each rule contains `patterns`, a list of Lua patterns matched against the callee
rather than the whole line. A rule can also set its own `require_args` value and
numeric `priority`; higher-priority matches classify a call before broader
rules, even when that specific group is disabled.

For example, `"%.Info$"` matches both `log.Info(...)` and `logger.Info(...)`.
Member accessors retain `.`, `::`, or `->`; use `"[%.:>]info$"` when all three
should match.

Specs are deep-merged by key. Adding a new level preserves existing rules;
assigning an existing rule's `patterns` replaces its entire pattern list.
Ensure the new rule is enabled through `groups` or `language_groups`.

A new filetype also needs `call_node_types`, a corresponding lazy.nvim `ft`
entry, and usually a Treesitter parser. Use `:InspectTree` to find its call node
types.

The conservative fallback recognizes ordinary `callee(...)` and parenthesized
`name!(...)` forms while ignoring common strings and comments. Stream
expressions, parenthesis-free calls, and other grammar-specific syntax require
Treesitter.

## API

```lua
local distill = require("distill")

distill.setup(opts)    -- lazy.nvim calls this through `opts`
distill.fold(bufnr)    -- bufnr is optional and defaults to the current buffer
distill.unfold(bufnr)
distill.toggle(bufnr)
distill.refresh(bufnr)
distill.list(bufnr)    -- populate quickfix with detections
distill.config(bufnr)  -- open the group picker
distill.detect(bufnr)  -- enabled detections with group/subgroup/level metadata
distill.enable()
distill.disable()
```

`detect()` returns matches before adjacent regions are merged and before
`min_lines` is applied.

## Health and development

```sh
nvim --headless -u NORC -c "luafile tests/run.lua"        # folding behavior
nvim --headless -u NORC -c "luafile tests/languages.lua"  # language catalog
nvim --headless -u NORC -c "luafile tests/lifecycle.lua"  # setup and restore
```

`tests/languages.lua` skips languages without an installed parser. Set
`DISTILL_PARSERS` to a directory of `<lang>.so` files to test parsers outside
your runtimepath.

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
