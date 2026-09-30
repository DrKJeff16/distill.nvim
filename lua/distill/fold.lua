local config = require("distill.config")
local detect = require("distill.detect")

local M = {}

local OUR_FOLDEXPR = "v:lua.require'distill.fold'.expr()"
local OUR_FOLDEXPR_ALT = "(v:lua.require'distill.fold'.expr())"
local TREESITTER_FOLDEXPR = "v:lua.vim.treesitter.foldexpr()"
local LSP_FOLDEXPR = "v:lua.vim.lsp.foldexpr()"
local REGION_NS = vim.api.nvim_create_namespace("distill-regions")

-- One active attachment per window. Sessions survive buffer switches so
-- extmarks can preserve the identity and open state of regions through edits.
M._states = {} -- winid -> active attachment
M._sessions = {} -- winid -> bufnr -> { marks, autofolded, detection }
M._notified_errors = {}

local function notify(message, level)
  vim.notify("distill: " .. message, level or vim.log.levels.WARN)
end

local function report_once(context, err)
  local message = ("%s: %s"):format(context, tostring(err))
  if M._notified_errors[message] then
    return
  end
  M._notified_errors[message] = true
  vim.schedule(function()
    notify(message, vim.log.levels.ERROR)
  end)
end

function M.reset_errors()
  M._notified_errors = {}
end

M.report_error = report_once

local function zero_base()
  return 0
end

local function treesitter_base(lnum)
  local ok, value = pcall(vim.treesitter.foldexpr, lnum)
  return ok and value ~= nil and value or 0
end

local function lsp_base(lnum)
  if not vim.lsp.foldexpr then
    return 0
  end
  local ok, value = pcall(vim.lsp.foldexpr, lnum)
  return ok and value ~= nil and value or 0
end

local function is_ours(expr)
  return expr == OUR_FOLDEXPR or expr == OUR_FOLDEXPR_ALT
end

M.is_ours = is_ours

function M.provider_kind(expr)
  if expr == TREESITTER_FOLDEXPR then
    return "treesitter"
  elseif expr == LSP_FOLDEXPR then
    return "lsp"
  end
  return nil
end

local function session_for(win, bufnr)
  M._sessions[win] = M._sessions[win] or {}
  local session = M._sessions[win][bufnr]
  if not session then
    session = { marks = {}, autofolded = false, detection = nil }
    M._sessions[win][bufnr] = session
  end
  return session
end

local function delete_mark(bufnr, mark)
  if vim.api.nvim_buf_is_valid(bufnr) and mark.id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, REGION_NS, mark.id)
  end
end

local function clear_session(bufnr, session)
  for _, mark in ipairs(session.marks or {}) do
    delete_mark(bufnr, mark)
  end
  session.marks = {}
  session.detection = nil
end

local function mark_position(bufnr, mark)
  if not mark.id or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, REGION_NS, mark.id, { details = true })
  if not ok or #pos == 0 then
    return nil
  end
  local details = pos[3] or {}
  return pos[1] + 1, details.end_row or (pos[1] + 1)
end

local function set_mark(bufnr, mark, region)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  mark.id = vim.api.nvim_buf_set_extmark(bufnr, REGION_NS, region.start - 1, 0, {
    id = mark.id,
    end_row = math.min(region["end"], line_count),
    end_col = 0,
    right_gravity = true,
    end_right_gravity = true,
  })
end

local function reconcile_regions(bufnr, session, regions)
  local old = {}
  for _, mark in ipairs(session.marks or {}) do
    local start_line, end_line = mark_position(bufnr, mark)
    if start_line then
      old[#old + 1] = { mark = mark, start = start_line, ["end"] = end_line, used = false }
    else
      delete_mark(bufnr, mark)
    end
  end

  local marks = {}
  for _, region in ipairs(regions) do
    local match
    for _, candidate in ipairs(old) do
      if not candidate.used and candidate.start == region.start and candidate["end"] == region["end"] then
        match = candidate
        break
      end
    end
    if not match then
      for _, candidate in ipairs(old) do
        if
          not candidate.used
          and candidate.start <= region["end"]
          and region.start <= candidate["end"]
        then
          match = candidate
          break
        end
      end
    end

    local mark = match and match.mark or { closed = false, known = false }
    if match then
      match.used = true
    end
    region.is_new = not mark.known
    set_mark(bufnr, mark, region)
    region.mark = mark
    marks[#marks + 1] = mark
  end

  for _, candidate in ipairs(old) do
    if not candidate.used then
      delete_mark(bufnr, candidate.mark)
    end
  end
  session.marks = marks
  return regions
end

-- Resolve every base token to an absolute level while retaining explicit
-- same-level starts and ends. Returning absolute levels prevents a Distill fold
-- from changing the meaning of a later relative token such as `=` or `s1`.
local function resolve_base(raw, count)
  local levels, starts, ends = {}, {}, {}
  local previous, pending, pending_before = 0, {}, nil

  local function resolve_pending(level)
    if #pending == 0 then
      return
    end
    local resolved = pending_before == nil and level or math.min(pending_before, level)
    for _, lnum in ipairs(pending) do
      levels[lnum] = resolved
    end
    pending, pending_before = {}, nil
  end

  for lnum = 1, count do
    local value = tostring(raw[lnum] == nil and 0 or raw[lnum])
    local head, number = value:sub(1, 1), tonumber(value:sub(2))
    local current, next_level
    if value == "-1" then
      if #pending == 0 then
        pending_before = lnum > 1 and previous or nil
      end
      pending[#pending + 1] = lnum
    elseif value == "=" then
      current, next_level = previous, previous
    elseif head == "a" then
      current = math.max(0, previous + (number or 0))
      next_level = current
      starts[lnum] = current > previous
    elseif head == "s" then
      current = previous
      next_level = math.max(0, previous - (number or 0))
      ends[lnum] = next_level < current
    elseif head == ">" then
      current = math.max(0, number or previous)
      next_level = current
      starts[lnum] = current > 0
    elseif head == "<" then
      current = math.max(0, number or previous)
      next_level = math.max(0, current - 1)
      ends[lnum] = current > 0
    else
      local numeric = tonumber(value)
      current = numeric and numeric >= 0 and numeric or previous
      next_level = current
    end

    if current ~= nil then
      resolve_pending(current)
      levels[lnum] = current
      previous = next_level
    end
  end
  resolve_pending(previous)
  return levels, starts, ends
end

-- Merge adjacent calls only when doing so does not cross a base-fold boundary.
local function fold_regions(detected, opts, levels, starts, ends)
  local merged = {}
  for _, region in ipairs(detected) do
    local previous = merged[#merged]
    local overlaps = previous and region.start <= previous["end"]
    local adjacent = previous and region.start == previous["end"] + 1
    local compatible = adjacent
      and levels[previous["end"]] == levels[region.start]
      and not ends[previous["end"]]
      and not starts[region.start]
    if previous and (overlaps or compatible) then
      previous["end"] = math.max(previous["end"], region["end"])
    else
      merged[#merged + 1] = {
        start = region.start,
        ["end"] = region["end"],
        group = region.group,
        subgroup = region.subgroup,
        level = region.level,
      }
    end
  end

  local out = {}
  for _, region in ipairs(merged) do
    if region["end"] - region.start + 1 >= opts.min_lines then
      out[#out + 1] = region
    end
  end
  return out
end

local function close_regions(win, regions)
  if #regions == 0 then
    return
  end
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.wo.foldenable = true
    for _, region in ipairs(regions) do
      if vim.fn.foldlevel(region.start) > 0 and vim.fn.foldclosed(region.start) == -1 then
        vim.fn.cursor(region.start, 1)
        pcall(vim.cmd, "normal! zc")
      end
    end
    vim.fn.winrestview(view)
  end)
end

local function open_regions(win, regions)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    for _, region in ipairs(regions) do
      if vim.fn.foldclosed(region.start) == region.start then
        vim.fn.cursor(region.start, 1)
        pcall(vim.cmd, "normal! zo")
      end
    end
    vim.fn.winrestview(view)
  end)
end

local function capture_closed(state)
  if not state.cache or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  vim.api.nvim_win_call(state.win, function()
    for _, region in ipairs(state.cache.regions) do
      local start_line = region.mark and mark_position(state.bufnr, region.mark) or region.start
      if start_line then
        local closed = vim.fn.foldclosed(start_line)
        if closed == -1 then
          region.mark.closed = false
        elseif closed == start_line then
          region.mark.closed = true
        end
      end
    end
  end)
end

local function invalidate_window(state)
  state.last_lnum = nil
  if vim.api.nvim_win_is_valid(state.win) then
    local current = vim.api.nvim_get_option_value("foldexpr", { win = state.win })
    if is_ours(current) then
      local replacement = current == OUR_FOLDEXPR and OUR_FOLDEXPR_ALT or OUR_FOLDEXPR
      vim.api.nvim_set_option_value("foldexpr", replacement, { win = state.win })
    end
  end
end

local function close_marked(state)
  local regions = {}
  for _, region in ipairs(state.cache and state.cache.regions or {}) do
    if region.mark and region.mark.closed then
      regions[#regions + 1] = region
    end
  end
  close_regions(state.win, regions)
end

local function base_value(state, lnum)
  local ok, value = pcall(state.base, lnum)
  if not ok then
    report_once("base fold provider failed", value)
    return 0
  end
  if value == nil then
    return 0
  end
  return value
end

-- Recompute provider values on every fold-evaluation pass. Detection itself is
-- cached by text tick and configuration generation because it cannot change
-- asynchronously like LSP and Treesitter folding providers can.
function M._recompute(bufnr, win, reuse_detection)
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win
  local state = M._states[win]
  local count = vim.api.nvim_buf_line_count(bufnr)
  local base = state and state.bufnr == bufnr and state.base or config.options.base_foldexpr or zero_base
  local raw = {}

  vim.api.nvim_win_call(win, function()
    for lnum = 1, count do
      raw[lnum] = state and base_value(state, lnum) or base(lnum)
    end
  end)
  local levels, base_starts, base_ends = resolve_base(raw, count)

  local session = state and state.session or { marks = {}, detection = nil }
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local detection = reuse_detection and session.detection
  if not detection or detection.tick ~= tick or detection.generation ~= config.generation then
    local ok, regions = pcall(detect.detect, bufnr)
    if not ok then
      report_once("detection failed", regions)
      regions = {}
    end
    detection = { tick = tick, generation = config.generation, regions = regions }
    session.detection = detection
  end

  local regions = fold_regions(detection.regions, config.options, levels, base_starts, base_ends)
  if state then
    regions = reconcile_regions(bufnr, session, regions)
  end

  local combined, diagnostic_starts, diagnostic_ends = vim.deepcopy(levels), {}, {}
  for _, region in ipairs(regions) do
    for lnum = region.start, region["end"] do
      combined[lnum] = (combined[lnum] or 0) + 1
    end
    diagnostic_starts[region.start] = true
    diagnostic_ends[region["end"]] = true
  end

  local result = {}
  for lnum = 1, count do
    local level = combined[lnum] or 0
    local previous = combined[lnum - 1] or 0
    local following = combined[lnum + 1] or 0
    local starts = diagnostic_starts[lnum] or base_starts[lnum] or level > previous
    local ends = diagnostic_ends[lnum] or base_ends[lnum] or level > following
    if starts and level > 0 then
      result[lnum] = ">" .. level
    elseif ends and level > 0 then
      result[lnum] = "<" .. level
    else
      result[lnum] = tostring(level)
    end
  end

  local cache = {
    tick = tick,
    generation = config.generation,
    result = result,
    regions = regions,
    base_levels = levels,
  }
  if state and state.bufnr == bufnr then
    state.cache = cache
    state.last_lnum = nil
  end
  return cache
end

function M.expr()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local state = M._states[win]
  if not config.options.enable or not state or state.bufnr ~= bufnr then
    return "0"
  end

  local lnum = vim.v.lnum
  local cache = state.cache
  if
    not cache
    or cache.tick ~= vim.api.nvim_buf_get_changedtick(bufnr)
    or cache.generation ~= config.generation
    or (state.last_lnum and lnum <= state.last_lnum)
  then
    cache = M._recompute(bufnr, win, true)
  end
  state.last_lnum = lnum
  return cache.result[lnum] or "0"
end

local function has_manual_folds(win, bufnr)
  local found = false
  vim.api.nvim_win_call(win, function()
    for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
      if vim.fn.foldlevel(lnum) > 0 then
        found = true
        break
      end
    end
  end)
  return found
end

local function inherited_state(bufnr, excluded_win)
  for win, state in pairs(M._states) do
    if win ~= excluded_win and state.bufnr == bufnr then
      return state
    end
  end
  return nil
end

function M.attach(bufnr, win)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return false, "buffer is not displayed in the target window"
  end

  local current_expr = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
  local current_method = vim.api.nvim_get_option_value("foldmethod", { win = win })
  local current_state = M._states[win]
  if current_state and current_state.bufnr == bufnr and is_ours(current_expr) then
    return true
  elseif current_state and current_state.bufnr ~= bufnr then
    M._states[win] = nil
  end

  local inherited = is_ours(current_expr)
  local source = inherited and inherited_state(bufnr, win) or nil
  if not inherited and current_method ~= "expr" and current_method ~= "manual" then
    return false, ("foldmethod=%s is not supported"):format(current_method)
  elseif not inherited and current_method == "manual" and has_manual_folds(win, bufnr) then
    return false, "manual folds already exist in this window"
  elseif inherited and not source then
    return false, "inherited Distill foldexpr has no owning window"
  end

  local base = config.options.base_foldexpr
  if not base then
    local kind = M.provider_kind(current_expr)
    if kind == "treesitter" then
      base = treesitter_base
    elseif kind == "lsp" then
      base = lsp_base
    elseif inherited then
      base = source.base
    elseif current_method == "expr" and current_expr ~= "" and current_expr ~= "0" then
      return false, "custom foldexpr requires the base_foldexpr option"
    else
      base = zero_base
    end
  end

  local previous
  if inherited then
    previous = vim.deepcopy(source.prev)
  else
    previous = {
      foldmethod = current_method,
      foldexpr = current_expr,
      foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win }),
      foldminlines = vim.api.nvim_get_option_value("foldminlines", { win = win }),
      foldenable = vim.api.nvim_get_option_value("foldenable", { win = win }),
      manual_empty = current_method == "manual",
    }
  end

  local state = {
    win = win,
    bufnr = bufnr,
    base = base,
    prev = previous,
    session = session_for(win, bufnr),
    cache = nil,
    last_lnum = nil,
  }
  M._states[win] = state
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = win })
  vim.api.nvim_set_option_value("foldexpr", OUR_FOLDEXPR, { win = win })
  if previous.foldmethod == "manual" then
    vim.api.nvim_set_option_value("foldlevel", 99, { win = win })
  end
  if config.options.min_lines <= 1 then
    vim.api.nvim_set_option_value("foldminlines", 0, { win = win })
  end
  M._recompute(bufnr, win, true)
  for _, region in ipairs(state.cache.regions) do
    region.mark.known = true
  end
  invalidate_window(state)
  return true
end

function M.ensure_attached(bufnr, win)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  win = (not win or win == 0) and vim.api.nvim_get_current_win() or win
  local state = M._states[win]
  local expr = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
  if state and state.bufnr == bufnr and is_ours(expr) then
    return true
  end
  return M.attach(bufnr, win)
end

function M.window_for(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == bufnr then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
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

local function prepare(bufnr, quiet)
  if not config.options.enable then
    if not quiet then
      notify("disabled")
    end
    return nil
  end
  local filetype = vim.bo[bufnr].filetype
  if not config.options.languages[filetype] then
    if not quiet then
      notify(("unsupported filetype %q"):format(filetype))
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
  local ok, reason = M.ensure_attached(bufnr, win)
  if not ok then
    if not quiet and reason then
      notify(reason)
    end
    return nil
  end
  return win, M._states[win]
end

local function recompute_state(state, reuse_detection)
  capture_closed(state)
  state.cache = nil
  local cache = M._recompute(state.bufnr, state.win, reuse_detection)
  invalidate_window(state)
  return cache
end

function M.close(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = recompute_state(state, false).regions
  for _, region in ipairs(regions) do
    region.mark.closed = true
    region.mark.known = true
  end
  close_regions(win, regions)
  return true
end

function M.close_new(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, true)
  if not win then
    return false
  end
  local regions = recompute_state(state, false).regions
  for _, region in ipairs(regions) do
    if region.is_new then
      region.mark.closed = true
    end
    region.mark.known = true
  end
  close_marked(state)
  return true
end

function M.open(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = recompute_state(state, false).regions
  for _, region in ipairs(regions) do
    region.mark.closed = false
    region.mark.known = true
  end
  open_regions(win, regions)
  return true
end

function M.toggle(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local win, state = prepare(bufnr, false)
  if not win then
    return false
  end
  local regions = recompute_state(state, false).regions
  local any_closed = false
  vim.api.nvim_win_call(win, function()
    for _, region in ipairs(regions) do
      if vim.fn.foldclosed(region.start) == region.start then
        any_closed = true
        break
      end
    end
  end)
  if any_closed then
    return M.open(bufnr)
  end
  return M.close(bufnr)
end

function M.refresh(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local _, state = prepare(bufnr, false)
  if not state then
    return false
  end
  recompute_state(state, false)
  for _, region in ipairs(state.cache.regions) do
    region.mark.known = true
  end
  close_marked(state)
  return true
end

function M.restore(bufnr, win)
  win = win or M.window_for(bufnr)
  local state = win and M._states[win]
  if not state or state.bufnr ~= bufnr then
    return false
  end
  recompute_state(state, true)
  close_marked(state)
  return true
end

function M.list(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not config.options.enable then
    notify("disabled")
    return false
  end
  local filetype = vim.bo[bufnr].filetype
  if not config.options.languages[filetype] then
    notify(("unsupported filetype %q"):format(filetype))
    return false
  end
  local regions = detect.detect(bufnr)
  if #regions == 0 then
    notify("no configured statements detected", vim.log.levels.INFO)
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  for _, region in ipairs(regions) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = region.start,
      end_lnum = region["end"],
      text = vim.trim(lines[region.start] or region.text or ""),
    }
  end
  vim.fn.setqflist({}, " ", { title = "distill: detected", items = items })
  vim.cmd("botright copen")
  return true
end

local function restore_options(win, previous)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_option_value("foldexpr", previous.foldexpr or "0", { win = win })
  vim.api.nvim_set_option_value("foldmethod", previous.foldmethod or "manual", { win = win })
  if previous.manual_empty and previous.foldmethod == "manual" then
    vim.api.nvim_win_call(win, function()
      pcall(vim.cmd, "normal! zE")
    end)
  end
  if previous.foldlevel ~= nil then
    vim.api.nvim_set_option_value("foldlevel", previous.foldlevel, { win = win })
  end
  if previous.foldminlines ~= nil then
    vim.api.nvim_set_option_value("foldminlines", previous.foldminlines, { win = win })
  end
  if previous.foldenable ~= nil then
    vim.api.nvim_set_option_value("foldenable", previous.foldenable, { win = win })
  end
end

function M.detach_window(win, bufnr)
  win = tonumber(win)
  local state = M._states[win]
  if not state or (bufnr and state.bufnr ~= bufnr) then
    return false
  end
  capture_closed(state)
  if vim.api.nvim_win_is_valid(win) then
    local current = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
    if is_ours(current) then
      restore_options(win, state.prev)
    end
  end
  M._states[win] = nil
  return true
end

function M.detach_all()
  local inherited = {}
  local attached_windows = {}
  for _, state in pairs(M._states) do
    inherited[state.bufnr] = inherited[state.bufnr] or vim.deepcopy(state.prev)
  end
  for win in pairs(M._states) do
    attached_windows[#attached_windows + 1] = win
  end
  for _, win in ipairs(attached_windows) do
    M.detach_window(win)
  end
  -- A split may inherit our window-local options before its scheduled attach.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local current = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
    if is_ours(current) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      restore_options(win, inherited[bufnr] or {
        foldmethod = "manual",
        foldexpr = "0",
        foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win }),
        foldminlines = vim.api.nvim_get_option_value("foldminlines", { win = win }),
        foldenable = vim.api.nvim_get_option_value("foldenable", { win = win }),
        manual_empty = true,
      })
    end
  end
  for win, buffers in pairs(M._sessions) do
    for bufnr, session in pairs(buffers) do
      clear_session(bufnr, session)
    end
    M._sessions[win] = nil
  end
  M._states = {}
end

function M.forget_window(win)
  win = tonumber(win)
  local buffers = M._sessions[win] or {}
  for bufnr, session in pairs(buffers) do
    clear_session(bufnr, session)
  end
  M._sessions[win] = nil
  M._states[win] = nil
end

function M.forget_buffer(bufnr)
  for win, buffers in pairs(M._sessions) do
    local session = buffers[bufnr]
    if session then
      clear_session(bufnr, session)
      buffers[bufnr] = nil
    end
    local state = M._states[win]
    if state and state.bufnr == bufnr then
      M._states[win] = nil
    end
  end
end

function M.rearm(bufnr)
  for _, buffers in pairs(M._sessions) do
    local session = buffers[bufnr]
    if session then
      clear_session(bufnr, session)
      session.autofolded = false
    end
  end
end

return M
