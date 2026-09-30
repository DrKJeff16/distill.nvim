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

-- Callback mappings are occupied even though maparg exposes no string rhs.
local callback_runs = 0
local callback = function()
  callback_runs = callback_runs + 1
end
vim.keymap.set("n", "<leader>df", callback)
distill.setup({ auto_fold = false })
local callback_mapping = vim.fn.maparg("<leader>df", "n", false, true)
check("setup: preserves an existing callback mapping", callback_mapping.callback == callback, vim.inspect(callback_mapping))
distill.disable()
check("disable: leaves the callback mapping intact", vim.fn.maparg("<leader>df", "n", false, true).callback == callback)
vim.keymap.del("n", "<leader>df")

-- A user replacement is no longer Distill's mapping, even if it preserves the
-- generated description.
distill.setup({ auto_fold = false, keymaps = { fold = "<leader>x" } })
vim.keymap.set("n", "<leader>x", "<cmd>echo 'replacement'<cr>", { desc = "Distill: close configured folds" })
distill.disable()
local replacement = vim.fn.maparg("<leader>x", "n")
check("disable: preserves a user replacement with the same description", replacement:find("replacement", 1, true), replacement)
vim.keymap.del("n", "<leader>x")

-- Removing a global Distill mapping is not confused by a buffer-local mapping
-- that shadows it.
distill.setup({ auto_fold = false, keymaps = { fold = "<leader>x" } })
vim.keymap.set("n", "<leader>x", "<cmd>echo 'local'<cr>", { buffer = true })
distill.disable()
local global_exists = false
for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
  if mapping.lhsraw == vim.api.nvim_replace_termcodes("<leader>x", true, true, true) then
    global_exists = true
  end
end
check("disable: removes a shadowed global Distill mapping", not global_exists)
check("disable: preserves the shadowing buffer mapping", vim.fn.maparg("<leader>x", "n") ~= "")
vim.keymap.del("n", "<leader>x", { buffer = true })

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

-- A plain split attaches through lifecycle events; callers do not need to invoke
-- internal attachment functions to make restoration safe.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = false })
buf = python_buffer()
local split_original_method = vim.wo.foldmethod
local split_original_expr = vim.wo.foldexpr
fold.close(buf)
win1 = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
win2 = vim.api.nvim_get_current_win()
vim.wait(200, function()
  return fold._states[win2] ~= nil
end)
check("split events: inherited window attaches automatically", fold._states[win2] ~= nil)
distill.disable()
check(
  "split events: inherited window restores on disable",
  vim.wo[win2].foldmethod == split_original_method and vim.wo[win2].foldexpr == split_original_expr,
  vim.wo[win2].foldmethod .. ":" .. vim.wo[win2].foldexpr
)
vim.api.nvim_win_close(win2, true)
vim.api.nvim_set_current_win(win1)

-- Leaving a buffer restores its options before Neovim saves that window view,
-- so a later disable cannot leave an orphaned Distill expression behind.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = false })
buf = python_buffer()
local hidden_original_expr = vim.wo.foldexpr
fold.close(buf)
vim.cmd("enew!")
check("buffer leave: active attachment is detached", fold._states[vim.api.nvim_get_current_win()] == nil)
distill.disable()
vim.cmd("buffer " .. buf)
check("hidden buffer: original foldexpr survives disable", vim.wo.foldexpr == hidden_original_expr, vim.wo.foldexpr)

-- Existing manual folds are never destroyed. Empty manual folding can be used,
-- and disabling removes generated folds and restores foldenable.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = false })
buf = python_buffer()
vim.wo.foldmethod = "manual"
vim.cmd("1,2fold")
ok, reason = fold.attach(buf, 0)
check("manual folds: attachment is refused when folds exist", not ok and reason:find("manual folds", 1, true), reason)
vim.cmd("normal! zE")
vim.wo.foldenable = false
check("manual folds: empty manual window attaches", fold.attach(buf, 0))
fold.close(buf)
distill.disable()
check("manual folds: foldenable is restored", vim.wo.foldenable == false)
check("manual folds: generated folds are removed", vim.wo.foldmethod == "manual" and vim.fn.foldlevel(1) == 0)

-- Relative base tokens are resolved before composition, so a one-line Distill
-- fold cannot leak into a following `=` line or shift an `s1` boundary.
local tokens = { ">1", "=", "=", "s1", "0" }
distill.setup({
  auto_fold = false,
  min_lines = 1,
  keymaps = false,
  base_foldexpr = function(lnum)
    return tokens[lnum] or 0
  end,
})
buf = python_buffer()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 1", 'logger.info("x")', "x = 2", "x = 3", "x = 4" })
check("compose: relative provider attaches", fold.attach(buf, 0))
local composed = fold._recompute(buf, 0, false)
check("compose: base levels honor = and s1", vim.deep_equal(composed.base_levels, { 1, 1, 1, 1, 0 }), vim.inspect(composed.base_levels))
check("compose: diagnostic starts one level deeper", composed.result[2] == ">2", vim.inspect(composed.result))
vim.wo.foldenable = true
vim.wo.foldexpr = vim.wo.foldexpr
check("compose: following line remains at the base level", vim.fn.foldlevel(3) == 1, vim.fn.foldlevel(3))
distill.disable()

-- Provider values are not frozen to changedtick: an asynchronous provider
-- update is visible even when the buffer text is unchanged.
local dynamic_level = 0
distill.setup({
  auto_fold = false,
  keymaps = false,
  base_foldexpr = function()
    return dynamic_level
  end,
})
buf = python_buffer()
fold.attach(buf, 0)
local unchanged_tick = vim.api.nvim_buf_get_changedtick(buf)
check("provider cache: initial level is zero", fold._recompute(buf, 0, true).base_levels[3] == 0)
dynamic_level = 2
check(
  "provider cache: updates without a text change",
  vim.api.nvim_buf_get_changedtick(buf) == unchanged_tick and fold._recompute(buf, 0, true).base_levels[3] == 2
)
distill.disable()

-- Extmarks preserve region identity across edits, even when a new block has the
-- same callees as existing blocks.
distill.setup({ auto_fold = false, base_foldexpr = zero, min_lines = 1, keymaps = false })
buf = python_buffer()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'logger.info("old one")',
  "x = 1",
  'logger.info("old two")',
  "x = 2",
})
fold.close(buf)
fold.open(buf)
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'logger.info("new")', "x = 0" })
fold._recompute(buf, 0, true) -- emulate a passive foldexpr pass before BufWritePost
fold.close_new(buf)
check("region identity: newly inserted duplicate closes", vim.fn.foldclosed(1) == 1, vim.fn.foldclosed(1))
check("region identity: shifted existing duplicate stays open", vim.fn.foldclosed(3) == -1, vim.fn.foldclosed(3))
check("region identity: second existing duplicate stays open", vim.fn.foldclosed(5) == -1, vim.fn.foldclosed(5))

vim.cmd("normal! zR")
fold.refresh(buf)
check("refresh: native zR open state is preserved", vim.fn.foldclosed(1) == -1, vim.fn.foldclosed(1))
distill.disable()

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
local bad_language_groups = pcall(distill.setup, { language_groups = { python = true } })
check("config: rejects non-table per-language group overrides", not bad_language_groups)
local bad_language = pcall(distill.setup, { languages = { custom = { groups = {} } } })
check("config: rejects incomplete language specs", not bad_language)

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

-- Automatic provider failures are surfaced once instead of being swallowed or
-- repeatedly notifying during foldexpr evaluation.
local notifications = {}
old_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
distill.setup({
  auto_fold = false,
  keymaps = false,
  base_foldexpr = function()
    error("provider boom")
  end,
})
buf = python_buffer()
fold.attach(buf, 0)
fold._recompute(buf, 0, true)
vim.wait(100, function()
  return #notifications > 0
end)
local provider_errors = 0
for _, message in ipairs(notifications) do
  if message:find("base fold provider failed", 1, true) then
    provider_errors = provider_errors + 1
  end
end
check("errors: provider failure is reported once", provider_errors == 1, vim.inspect(notifications))
distill.disable()
vim.notify = old_notify

-- Health checks run inside a health:// buffer, so they must inspect loaded
-- supported buffers rather than assuming the current buffer is the source.
distill.setup({ enable = false, keymaps = false })
local source = python_buffer()
vim.cmd("enew!")
local health_messages = {}
local old_health = vim.health
vim.health = {
  start = function(message)
    health_messages[#health_messages + 1] = message
  end,
  ok = function(message)
    health_messages[#health_messages + 1] = message
  end,
  info = function(message)
    health_messages[#health_messages + 1] = message
  end,
  warn = function(message)
    health_messages[#health_messages + 1] = message
  end,
}
require("distill.health").check()
vim.health = old_health
check(
  "health: reports a loaded supported source buffer",
  table.concat(health_messages, " "):find('configured filetype "python"', 1, true) ~= nil,
  vim.inspect(health_messages)
)
check("health setup: source buffer remains loaded", vim.api.nvim_buf_is_loaded(source))
check("health: lookalike fold expressions are not recognized", not fold.is_ours("v:lua.fake_distill.fold()"))

print(("\n%d failure(s)"):format(failures))
vim.cmd((failures == 0) and "qa!" or "cq!")
