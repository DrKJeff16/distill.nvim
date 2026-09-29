local config = require("distill.config")
local detect = require("distill.detect")

local M = {}

local OUR_FOLDEXPR = "v:lua.require'distill.fold'.expr()"

-- Folding options and closed folds are window-local in Neovim, so attachment
-- state must be window-local too. Each entry records the buffer currently using
-- Distill in that window and the settings that should be restored on detach.
M._states = {} -- winid -> { bufnr, base, prev, cache, closed, known, autofolded }

-- Default base: Treesitter folds. Safe to call on any line; returns "0" if no
-- parser so we never throw inside a foldexpr.
local function default_base(lnum)
  local ok, r = pcall(vim.treesitter.foldexpr, lnum)
  if ok and r ~= nil then
    return r
  end
  return 0
end

local function is_ours(expr)
  return expr == OUR_FOLDEXPR
end

local function inherited_state(bufnr, state)
  if state then
    return state
  end
  -- A new split inherits window-local options, including our foldexpr. Reuse
  -- the source window's original settings so the split can restore cleanly.
  for _, candidate in pairs(M._states) do
    if candidate.bufnr == bufnr then
      return candidate
    end
  end
  return nil
end

-- Resolve a single foldexpr token to an absolute fold level given the previous
-- line's resolved level. Handles the forms documented in `:h fold-expr`.
local function resolve(value, prev)
  local s = tostring(value)
  if s == "=" then
    return prev
  end
  local head = s:sub(1, 1)
  if head == ">" or head == "<" then
    return tonumber(s:sub(2)) or prev
  elseif head == "a" then
    return prev + (tonumber(s:sub(2)) or 0)
  elseif head == "s" then
    return math.max(0, prev - (tonumber(s:sub(2)) or 0))
  end
  local num = tonumber(s)
  if not num or num < 0 then
    return prev -- -1 ("undefined") and junk: approximate with previous level
  end
  return num
end

local function signature(region)
  return table.concat(region.texts or {}, "\n")
end

local function signatures(regions)
  local out = {}
  for _, r in ipairs(regions) do
    local key = signature(r)
    out[key] = (out[key] or 0) + 1
  end
  return out
end

-- Merge adjacent detection regions and apply the min_lines filter. Returns the
-- regions that should actually become folds.
local function fold_regions(detected, opts)
  local merged = {}
  for _, r in ipairs(detected) do
    local prev = merged[#merged]
    if prev and r.start <= prev["end"] + 1 then
      prev["end"] = math.max(prev["end"], r["end"])
      prev.texts[#prev.texts + 1] = r.text or ""
    else
      merged[#merged + 1] = { start = r.start, ["end"] = r["end"], texts = { r.text or "" } }
    end
  end

  local out = {}
  for _, r in ipairs(merged) do
    local span = r["end"] - r.start + 1
    if span >= opts.min_lines then
      out[#out + 1] = r
    end
  end
  return out
end

local function close_regions(win, regions)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    for _, r in ipairs(regions) do
      -- Only act when the line is currently visible (not hidden by a closed
      -- parent). `zc` then closes the innermost open fold, i.e. the logging one.
      if vim.fn.foldlevel(r.start) > 0 and vim.fn.foldclosed(r.start) == -1 then
        vim.fn.cursor(r.start, 1)
        pcall(vim.cmd, "normal! zc")
      end
    end
    vim.fn.winrestview(view)
  end)
end

-- Build (and cache) the per-line foldexpr result for `bufnr` in `win`. Non-logging lines
-- get the *verbatim* base value, so general folding is byte-for-byte identical
-- to whatever origami/treesitter/LSP produces. Only logging lines are rewritten
-- to nest one level deeper than their surroundings.
function M._recompute(bufnr, win)
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win
  local n = vim.api.nvim_buf_line_count(bufnr)
  local state = M._states[win]
  local base = (state and state.bufnr == bufnr and state.base) or config.options.base_foldexpr or default_base

  local raw, levels, prev = {}, {}, 0
  vim.api.nvim_win_call(win, function()
    for l = 1, n do
      local v = base(l)
      raw[l] = v
      levels[l] = resolve(v, prev)
      prev = levels[l]
    end
  end)

  local regions = fold_regions(detect.detect(bufnr), config.options)

  local result = {}
  for l = 1, n do
    result[l] = raw[l]
  end
  for _, reg in ipairs(regions) do
    local lvl = (levels[reg.start] or 0) + 1
    result[reg.start] = ">" .. lvl
    for l = reg.start + 1, reg["end"] - 1 do
      result[l] = tostring(lvl)
    end
    if reg["end"] > reg.start then
      result[reg["end"]] = "<" .. lvl
    end
  end

  local cache = {
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    result = result,
    regions = regions,
  }
  if state and state.bufnr == bufnr then
    state.cache = cache
  end
  return cache
end

-- The foldexpr installed on attached buffers. Cheap: full computation happens
-- once per change, then every line is a table lookup.
function M.expr()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local state = M._states[win]
  local c = state and state.bufnr == bufnr and state.cache or nil
  if not c or c.tick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
    c = M._recompute(bufnr, win)
  end
  return c.result[vim.v.lnum] or "0"
end

-- Capture a base foldexpr and install ours. Returns false (without touching the
-- buffer) when we can't produce sensible general folds, so we never wipe out a
-- user's existing folding.
function M.attach(bufnr, win)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win

  local cur = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
  local cur_fm = vim.api.nvim_get_option_value("foldmethod", { win = win })
  local state = M._states[win]
  local inherited = is_ours(cur)
  local source = inherited and inherited_state(bufnr, state) or nil

  if inherited and state and state.bufnr == bufnr then
    return true
  end

  -- Don't clobber a deliberate non-expr folding setup (marker/indent/syntax/diff).
  -- We compose with `expr` (origami/treesitter/LSP) and will bootstrap from the
  -- inert `manual` default, but anything else is left alone.
  if not inherited and cur_fm ~= "expr" and cur_fm ~= "manual" then
    vim.b[bufnr].distill_skip = true
    return false, ("foldmethod=%s is not supported"):format(cur_fm)
  end
  local bootstrapping = not inherited and cur_fm ~= "expr"

  local base = config.options.base_foldexpr
  if not base then
    if cur:find("lsp") then
      base = function(l)
        local ok, r = pcall(vim.lsp.foldexpr, l)
        return (ok and r ~= nil) and r or 0
      end
    elseif cur:find("treesitter") then
      base = default_base
    elseif inherited then
      base = (source and source.base) or default_base
    elseif cur_fm == "expr" and cur ~= "" and cur ~= "0" then
      vim.b[bufnr].distill_skip = true
      return false, "custom foldexpr requires the base_foldexpr option"
    else
      -- With no general fold provider, use a zero-level base. Detection can
      -- still use its parser-less fallback without changing unrelated lines.
      base = default_base
    end
  end

  local prev
  if inherited then
    prev = source and vim.deepcopy(source.prev)
      or {
        foldmethod = "manual",
        foldexpr = "0",
        foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win }),
        foldminlines = vim.api.nvim_get_option_value("foldminlines", { win = win }),
      }
  else
    prev = {
      foldmethod = cur_fm,
      foldexpr = cur,
      foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win }),
      foldminlines = vim.api.nvim_get_option_value("foldminlines", { win = win }),
    }
  end

  local same_buffer = state and state.bufnr == bufnr
  M._states[win] = {
    bufnr = bufnr,
    base = base,
    prev = prev,
    cache = nil,
    closed = same_buffer and state.closed or false,
    known = same_buffer and state.known or {},
    autofolded = same_buffer and state.autofolded or false,
  }
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = win })
  vim.api.nvim_set_option_value("foldexpr", OUR_FOLDEXPR, { win = win })
  -- When we introduce expr folding ourselves, keep general folds open by default
  -- so only the logging folds (which we close explicitly) appear collapsed.
  if bootstrapping then
    vim.api.nvim_set_option_value("foldlevel", 99, { win = win })
  end
  -- A lone single-line fold only displays closed when 'foldminlines' is 0, so
  -- enable that when min_lines allows one-line logging folds.
  if config.options.min_lines <= 1 then
    vim.api.nvim_set_option_value("foldminlines", 0, { win = win })
  end
  return true
end

function M.ensure_attached(bufnr, win)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win
  local cur = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
  local state = M._states[win]
  if state and state.bufnr == bufnr and is_ours(cur) then
    return true
  end
  return M.attach(bufnr, win)
end

-- Find a window currently displaying `bufnr` (preferring the current one).
function M.window_for(bufnr)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == bufnr then
    return cur
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
  return nil
end

function M.windows_for(bufnr)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      out[#out + 1] = win
    end
  end
  return out
end

local function notify(message, level)
  vim.notify("distill: " .. message, level or vim.log.levels.WARN)
end

local function prepare(bufnr, quiet)
  if not config.options.enable then
    if not quiet then
      notify("disabled")
    end
    return nil
  end
  local ft = vim.bo[bufnr].filetype
  if not config.options.languages[ft] then
    if not quiet then
      notify(("unsupported filetype %q"):format(ft))
    end
    return nil
  end
  local win = M.window_for(bufnr)
  if not win then
    if not quiet then
      notify("buffer is not displayed in a window")
    end
    return nil
  end
  vim.b[bufnr].distill_skip = false
  local ok, reason = M.ensure_attached(bufnr, win)
  if not ok then
    if not quiet and reason then
      notify(reason)
    end
    return nil
  end
  return win, M._states[win]
end

local function any_closed(win, regions)
  local closed = false
  vim.api.nvim_win_call(win, function()
    for _, r in ipairs(regions) do
      if vim.fn.foldclosed(r.start) == r.start then
        closed = true
        break
      end
    end
  end)
  return closed
end

-- Close only the logging folds, leaving general folds (and parents the user has
-- closed) untouched.
function M.close(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = M._recompute(bufnr, win).regions

  close_regions(win, regions)
  state.known = signatures(regions)
  state.closed = true
  return true
end

-- Close only regions that were not present during the previous fold pass. Used
-- on write so manually opened existing logging folds stay open.
function M.close_new(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, true)
  if not win then
    return
  end
  local known = vim.deepcopy(state.known or {})
  local regions = M._recompute(bufnr, win).regions
  local new_regions = {}
  for _, r in ipairs(regions) do
    local key = signature(r)
    if (known[key] or 0) > 0 then
      known[key] = known[key] - 1
    else
      new_regions[#new_regions + 1] = r
    end
  end

  close_regions(win, new_regions)
  state.known = signatures(regions)
end

-- Open only the logging folds (folds that start exactly on a detected region).
function M.open(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = M._recompute(bufnr, win).regions

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    for _, r in ipairs(regions) do
      if vim.fn.foldclosed(r.start) == r.start then
        vim.fn.cursor(r.start, 1)
        pcall(vim.cmd, "normal! zo")
      end
    end
    vim.fn.winrestview(view)
  end)
  state.closed = false
  return true
end

function M.toggle(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = M._recompute(bufnr, win).regions
  if any_closed(win, regions) then
    M.open(bufnr)
  else
    M.close(bufnr)
  end
  return true
end

-- Recompute folds (e.g. after edits) and re-apply the closed state if active.
function M.refresh(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local should_close = state.cache and any_closed(win, state.cache.regions) or state.closed
  state.cache = nil
  -- Re-assert our foldexpr to force Neovim to recompute folds.
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = win })
  local regions = M._recompute(bufnr, win).regions
  if should_close then
    close_regions(win, regions)
  end
  state.closed = should_close
  state.known = signatures(regions)
  return true
end

-- Populate the quickfix list with detected logging statements.
function M.list(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not config.options.enable then
    notify("disabled")
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if not config.options.languages[ft] then
    notify(("unsupported filetype %q"):format(ft))
    return false
  end
  local regions = detect.detect(bufnr)
  if #regions == 0 then
    notify("no configured statements detected", vim.log.levels.INFO)
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  for _, r in ipairs(regions) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = r.start,
      end_lnum = r["end"],
      text = vim.trim(lines[r.start] or r.text or ""),
    }
  end
  vim.fn.setqflist({}, " ", { title = "distill: detected", items = items })
  vim.cmd("botright copen")
  return true
end

-- Restore original folding on every window we changed and forget all state.
function M.detach_all()
  for w, state in pairs(M._states) do
    if vim.api.nvim_win_is_valid(w) then
      local prev = state.prev
      local cur = vim.api.nvim_get_option_value("foldexpr", { win = w }) or ""
      if prev and is_ours(cur) then
        vim.api.nvim_set_option_value("foldmethod", prev.foldmethod or "manual", { win = w })
        vim.api.nvim_set_option_value("foldexpr", prev.foldexpr or "0", { win = w })
        if prev.foldlevel ~= nil then
          vim.api.nvim_set_option_value("foldlevel", prev.foldlevel, { win = w })
        end
        if prev.foldminlines ~= nil then
          vim.api.nvim_set_option_value("foldminlines", prev.foldminlines, { win = w })
        end
      end
    end
  end
  M._states = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.b[b].distill_skip = nil
    end
  end
end

function M.forget_window(win)
  M._states[tonumber(win)] = nil
end

function M.rearm(bufnr)
  for _, state in pairs(M._states) do
    if state.bufnr == bufnr then
      state.autofolded = false
    end
  end
end

return M
