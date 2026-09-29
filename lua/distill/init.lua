local config = require("distill.config")
local fold = require("distill.fold")
local detect = require("distill.detect")
local ui = require("distill.ui")

local M = {}

local actions = {
  fold = { command = "DistillFold", desc = "Distill: close configured folds" },
  unfold = { command = "DistillUnfold", desc = "Distill: open configured folds" },
  toggle = { command = "DistillToggle", desc = "Distill: toggle configured folds" },
  refresh = { command = "DistillRefresh", desc = "Distill: refresh configured folds" },
  list = { command = "DistillList", desc = "Distill: list detected statements" },
  config = { command = "DistillConfig", desc = "Distill: configure fold groups" },
}
local installed_keymaps = {}

local function clear_keymaps()
  for lhs, rhs in pairs(installed_keymaps) do
    local current = vim.fn.maparg(lhs, "n", false, true)
    if current.rhs == rhs then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  installed_keymaps = {}
end

local function install_keymaps()
  if not config.options.enable or type(config.options.keymaps) ~= "table" then
    return
  end
  for action, mapping in pairs(config.options.keymaps) do
    local spec = actions[action]
    if mapping and spec then
      local rhs = "<cmd>" .. spec.command .. "<cr>"
      local current = vim.fn.maparg(mapping, "n", false, true)
      if current.rhs == nil or current.rhs == "" then
        vim.keymap.set("n", mapping, rhs, { desc = spec.desc, silent = true })
        installed_keymaps[mapping] = rhs
      end
    end
  end
end

local function supported(buf)
  return config.options.languages[vim.bo[buf].filetype] ~= nil
    and config.options.languages[vim.bo[buf].filetype] ~= false
end

-- Attach to a freshly visible supported buffer and, if enabled, auto-fold once
-- per file load.
local function on_open(buf, win)
  if not config.options.enable or not vim.api.nvim_buf_is_valid(buf) or not supported(buf) then
    return
  end
  if vim.b[buf].distill_skip then -- already determined unsupported; stay quiet
    return
  end
  win = win or fold.window_for(buf)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  if not fold.ensure_attached(buf, win) then
    return
  end
  local state = fold._states[win]
  if config.options.auto_fold and not state.autofolded then
    state.autofolded = true
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and config.options.enable then
        vim.api.nvim_win_call(win, function()
          pcall(fold.close, buf)
        end)
      end
    end)
  end
end

local function on_write(buf)
  if
    not config.options.enable
    or not config.options.auto_fold
    or not vim.api.nvim_buf_is_valid(buf)
    or not supported(buf)
  then
    return
  end
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and config.options.enable and config.options.auto_fold then
      for _, win in ipairs(fold.windows_for(buf)) do
        vim.api.nvim_win_call(win, function()
          pcall(fold.close_new, buf)
        end)
      end
    end
  end)
end

function M.setup(opts)
  config.setup(opts)
  fold.detach_all()
  clear_keymaps()

  local group = vim.api.nvim_create_augroup("Distill", { clear = true })
  local fts = {}
  for ft, spec in pairs(config.options.languages) do
    if spec then
      fts[#fts + 1] = ft
    end
  end

  -- Defer to vim.schedule so attachment runs after every synchronous handler
  -- for the same event (e.g. origami's foldexpr setup), letting us capture the
  -- correct base foldexpr regardless of plugin load order.
  local function schedule_open(a)
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      on_open(a.buf, win)
    end)
  end

  if #fts > 0 then
    vim.api.nvim_create_autocmd("FileType", { group = group, pattern = fts, callback = schedule_open })
  end
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = schedule_open })
  -- Re-arm the one-shot auto-fold on every (re)load of the file.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(a)
      fold.rearm(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(a)
      on_write(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
    group = group,
    callback = function(a)
      -- Folding providers commonly change foldexpr on these events. Run after
      -- their synchronous handlers, then compose Distill over the new provider.
      vim.b[a.buf].distill_skip = false
      vim.schedule(function()
        for _, win in ipairs(fold.windows_for(a.buf)) do
          on_open(a.buf, win)
          local state = fold._states[win]
          if state and state.bufnr == a.buf and state.closed then
            vim.api.nvim_win_call(win, function()
              pcall(fold.refresh, a.buf)
            end)
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(a)
      fold.forget_window(a.match)
    end,
  })

  local cmd = vim.api.nvim_create_user_command
  cmd("DistillFold", function()
    fold.close()
  end, { desc = "Close configured Distill folds in the current buffer" })
  cmd("DistillUnfold", function()
    fold.open()
  end, { desc = "Open configured Distill folds in the current buffer" })
  cmd("DistillToggle", function()
    fold.toggle()
  end, { desc = "Toggle configured Distill folds in the current buffer" })
  cmd("DistillList", function()
    fold.list()
  end, { desc = "List detected Distill statements in the quickfix window" })
  cmd("DistillRefresh", function()
    fold.refresh()
  end, { desc = "Recompute configured Distill folds for the current buffer" })
  cmd("DistillEnable", function()
    M.enable()
  end, { desc = "Enable distill" })
  cmd("DistillDisable", function()
    M.disable()
  end, { desc = "Disable distill and restore original folding" })
  cmd("DistillConfig", function()
    ui.open()
  end, { desc = "Configure Distill fold groups for the current filetype" })

  install_keymaps()

  -- Handle buffers already open when setup() runs (e.g. lazy-loaded via :cmd).
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if supported(b) then
      vim.schedule(function()
        on_open(b, win)
      end)
    end
  end
end

function M.enable()
  config.options.enable = true
  install_keymaps()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if supported(b) then
      fold.ensure_attached(b, w)
    end
  end
end

function M.disable()
  config.options.enable = false
  fold.detach_all()
  clear_keymaps()
end

-- Public Lua API.
M.fold = function(buf)
  fold.close(buf)
end
M.unfold = function(buf)
  fold.open(buf)
end
M.toggle = function(buf)
  fold.toggle(buf)
end
M.list = function(buf)
  fold.list(buf)
end
M.refresh = function(buf)
  fold.refresh(buf)
end
M.detect = function(buf)
  return detect.detect(buf)
end
M.config = function(buf)
  return ui.open(buf)
end

return M
