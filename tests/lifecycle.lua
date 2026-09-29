-- Lifecycle and configuration regressions. Run from the repo root with:
--   nvim --headless -u NORC -c "luafile tests/lifecycle.lua"

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:append(root)

local failures = 0
local function check(name, cond, extra)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or ""))
  end
end

local distill = require("distill")
local fold = require("distill.fold")
local function zero()
  return 0
end

local function python_buffer()
  vim.cmd("enew!")
  vim.bo.filetype = "python"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    'logger.info("one")',
    'logger.warning("two")',
    "x = 1",
  })
  return vim.api.nvim_get_current_buf()
end

-- Disable restores the provider captured before attachment and removes only the
-- mappings Distill installed.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = { fold = "<leader>x" } })
local buf = python_buffer()
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.CustomFoldExpr()"
vim.wo.foldlevel = 7
vim.wo.foldminlines = 3
check("attach: custom provider accepted with base_foldexpr", fold.attach(buf, 0))
distill.disable()
check("disable: restores foldmethod", vim.wo.foldmethod == "expr", vim.wo.foldmethod)
check("disable: restores foldexpr", vim.wo.foldexpr == "v:lua.CustomFoldExpr()", vim.wo.foldexpr)
check("disable: restores foldlevel", vim.wo.foldlevel == 7, vim.wo.foldlevel)
check("disable: restores foldminlines", vim.wo.foldminlines == 3, vim.wo.foldminlines)
check("disable: removes installed keymap", vim.fn.maparg("<leader>x", "n") == "")

-- Disabled setup keeps control commands available, but installs no mappings and
-- action APIs do not mutate folding.
distill.setup({ enable = false })
local before = vim.wo.foldexpr
check("enable=false: no default keymap", vim.fn.maparg("<leader>df", "n") == "")
check("enable=false: enable command remains available", vim.fn.exists(":DistillEnable") == 2)
local old_notify = vim.notify
vim.notify = function() end
check("enable=false: fold action is a no-op", fold.close(buf) == false and vim.wo.foldexpr == before)
vim.notify = old_notify

-- Reconfiguration removes stale mappings and never overwrites a user's map.
distill.setup({ auto_fold = false, keymaps = { fold = "<leader>x" } })
distill.setup({ auto_fold = false, keymaps = false })
check("setup: keymaps=false removes an earlier Distill mapping", vim.fn.maparg("<leader>x", "n") == "")
vim.keymap.set("n", "<leader>df", "<cmd>echo 'user'<cr>")
distill.setup({ auto_fold = false })
local user_mapping = vim.fn.maparg("<leader>df", "n")
check("setup: preserves an existing user mapping", user_mapping:find("echo 'user'", 1, true) ~= nil, user_mapping)
vim.keymap.del("n", "<leader>df")
vim.keymap.set("n", "<leader>df", "<cmd>DistillFold<cr>")
distill.setup({ auto_fold = false })
distill.disable()
check("disable: preserves a pre-existing equivalent mapping", vim.fn.maparg("<leader>df", "n") ~= "")
vim.keymap.del("n", "<leader>df")

-- Toggle reads the actual fold state, so native zo/zc commands cannot make it stale.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = false })
buf = python_buffer()
local original_method, original_expr = vim.wo.foldmethod, vim.wo.foldexpr
fold.close(buf)
vim.cmd("normal! zo")
check("toggle setup: native zo opens the fold", vim.fn.foldclosed(1) == -1)
fold.toggle(buf)
check("toggle: closes after a native zo", vim.fn.foldclosed(1) == 1, vim.fn.foldclosed(1))

-- A split inheriting Distill's expression gets independent state and both
-- windows restore correctly.
local win1 = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local win2 = vim.api.nvim_get_current_win()
check("split: inherited window attaches", fold.attach(buf, win2))
distill.disable()
check(
  "split: first window restores",
  vim.api.nvim_get_option_value("foldmethod", { win = win1 }) == original_method
    and vim.api.nvim_get_option_value("foldexpr", { win = win1 }) == original_expr
)
check(
  "split: second window restores",
  vim.api.nvim_get_option_value("foldmethod", { win = win2 }) == original_method
    and vim.api.nvim_get_option_value("foldexpr", { win = win2 }) == original_expr
)
vim.api.nvim_win_close(win2, true)
vim.api.nvim_set_current_win(win1)

-- Unknown expression providers are left untouched unless the user supplies the
-- callable base_foldexpr needed for composition.
distill.setup({ auto_fold = false, keymaps = false })
buf = python_buffer()
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "CustomFoldExpr()"
local ok, reason = fold.attach(buf, 0)
check("custom foldexpr: attachment is refused", not ok and reason:find("base_foldexpr", 1, true) ~= nil, reason)
check("custom foldexpr: provider remains untouched", vim.wo.foldexpr == "CustomFoldExpr()", vim.wo.foldexpr)

-- Origami/LSP-style provider changes are picked up after LspAttach.
vim.wo.foldexpr = "v:lua.vim.lsp.foldexpr()"
vim.cmd("doautocmd LspAttach")
vim.wait(100, function()
  return vim.wo.foldexpr:find("distill.fold", 1, true) ~= nil
end)
check(
  "LspAttach: recomposes over the new provider",
  vim.wo.foldexpr:find("distill.fold", 1, true) ~= nil,
  vim.wo.foldexpr
)

local attached_expr = vim.wo.foldexpr
local valid = pcall(distill.setup, { min_lines = 0 })
check("config: rejects min_lines below one", not valid)
check("config: invalid setup leaves the current attachment intact", vim.wo.foldexpr == attached_expr)

-- Group inheritance is concise globally and can be narrowed by filetype down
-- to one level without losing a parent override.
distill.setup({
  enable = false,
  groups = { logging = { enabled = true, levels = { trace = false } }, output = false },
  language_groups = { python = { output = { print = true } } },
})
local config = require("distill.config")
check("groups: global family value is inherited", config.group_enabled("go", { "logging", "levels", "info" }))
check("groups: global level override wins", not config.group_enabled("go", { "logging", "levels", "trace" }))
check("groups: language subgroup override wins", config.group_enabled("python", { "output", "print", "builtin" }))
check(
  "groups: sibling keeps the global default",
  not config.group_enabled("python", { "output", "stack", "traceback" })
)
config.set_group("python", { "output" }, true)
config.set_group("python", { "output", "debugger" }, false)
check(
  "groups: child override preserves enabled parent",
  config.group_enabled("python", { "output", "print", "builtin" })
)
check("groups: child can override enabled parent", not config.group_enabled("python", { "output", "debugger", "pdb" }))
config.reset_groups("python")
check("groups: reset restores globals", not config.group_enabled("python", { "output", "print", "builtin" }))

local bad_groups = pcall(distill.setup, { groups = { logging = "yes" } })
check("config: rejects non-boolean group values", not bad_groups)
local bad_enabled = pcall(distill.setup, { groups = { logging = { enabled = {} } } })
check("config: rejects non-boolean enabled values", not bad_enabled)

-- The editor UI exposes every hierarchy level and applies a leaf toggle.
local old_select = vim.ui.select
local menus, rendered = 0, {}
vim.ui.select = function(items, opts, callback)
  menus = menus + 1
  for _, item in ipairs(items) do
    rendered[#rendered + 1] = opts.format_item(item)
  end
  local wanted = ({ "output", "print", "builtin" })[menus]
  if not wanted then
    callback(nil)
    return
  end
  for _, item in ipairs(items) do
    if item.name == wanted then
      callback(item)
      return
    end
  end
  callback(nil)
end
python_buffer()
check("ui: opens for a supported language", distill.config())
check("ui: navigates group, subgroup, and level", menus == 4, menus)
check("ui: toggles the selected level", config.group_enabled("python", { "output", "print", "builtin" }))
check("ui: renders effective state", table.concat(rendered, " "):find("%[off%] output") ~= nil)
vim.ui.select = old_select

print(("\n%d failure(s)"):format(failures))
vim.cmd((failures == 0) and "qa!" or "cq!")
