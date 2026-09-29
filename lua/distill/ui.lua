local config = require("distill.config")
local fold = require("distill.fold")

local M = {}

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function path_with(path, key)
  local copy = vim.deepcopy(path)
  copy[#copy + 1] = key
  return copy
end

local function leaves(node, path, out)
  out = out or {}
  if node.patterns then
    out[#out + 1] = path
    return out
  end
  for _, key in ipairs(sorted_keys(node)) do
    leaves(node[key], path_with(path, key), out)
  end
  return out
end

local function state(filetype, node, path)
  local enabled, total = 0, 0
  for _, leaf in ipairs(leaves(node, path)) do
    total = total + 1
    if config.group_enabled(filetype, leaf) then
      enabled = enabled + 1
    end
  end
  if enabled == 0 then
    return "off", false
  elseif enabled == total then
    return "on", true
  end
  return "mixed", false
end

local function refresh_visible()
  if not config.options.enable then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local filetype = vim.bo[bufnr].filetype
    if config.options.languages[filetype] then
      vim.api.nvim_win_call(win, function()
        fold.refresh(bufnr)
      end)
    end
  end
end

local open_group_menu
local open_level_menu

local function toggle(filetype, node, path)
  local _, all_enabled = state(filetype, node, path)
  config.set_group(filetype, path, not all_enabled)
  refresh_visible()
end

open_level_menu = function(bufnr, filetype, group_name, subgroup_name, node)
  local path = { group_name, subgroup_name }
  local items = { { kind = "toggle", label = "Toggle all" }, { kind = "back", label = "‹ Back" } }
  for _, level_name in ipairs(sorted_keys(node)) do
    items[#items + 1] = { kind = "level", label = level_name, name = level_name, node = node[level_name] }
  end
  vim.ui.select(items, {
    prompt = ("Distill %s › %s"):format(group_name, subgroup_name),
    format_item = function(item)
      if item.kind == "back" then
        return item.label
      end
      local item_node = item.node or node
      local item_path = item.name and path_with(path, item.name) or path
      local value = state(filetype, item_node, item_path)
      return ("[%s] %s"):format(value, item.label)
    end,
  }, function(item)
    if not item then
      return
    end
    if item.kind == "back" then
      open_group_menu(bufnr, filetype, group_name, config.options.languages[filetype].groups[group_name])
      return
    elseif item.kind == "toggle" then
      toggle(filetype, node, path)
    else
      toggle(filetype, item.node, path_with(path, item.name))
    end
    open_level_menu(bufnr, filetype, group_name, subgroup_name, node)
  end)
end

open_group_menu = function(bufnr, filetype, group_name, node)
  local path = { group_name }
  local items = { { kind = "toggle", label = "Toggle all" }, { kind = "back", label = "‹ Back" } }
  for _, subgroup_name in ipairs(sorted_keys(node)) do
    items[#items + 1] = {
      kind = "subgroup",
      label = subgroup_name,
      name = subgroup_name,
      node = node[subgroup_name],
    }
  end
  vim.ui.select(items, {
    prompt = ("Distill %s › %s"):format(filetype, group_name),
    format_item = function(item)
      if item.kind == "back" then
        return item.label
      end
      local item_node = item.node or node
      local item_path = item.name and path_with(path, item.name) or path
      local value = state(filetype, item_node, item_path)
      return ("[%s] %s"):format(value, item.label)
    end,
  }, function(item)
    if not item then
      return
    end
    if item.kind == "back" then
      M.open(bufnr)
    elseif item.kind == "toggle" then
      toggle(filetype, node, path)
      open_group_menu(bufnr, filetype, group_name, node)
    else
      open_level_menu(bufnr, filetype, group_name, item.name, item.node)
    end
  end)
end

function M.open(bufnr)
  bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local filetype = vim.bo[bufnr].filetype
  local spec = config.options.languages[filetype]
  if not spec then
    vim.notify(("distill: unsupported filetype %q"):format(filetype), vim.log.levels.WARN)
    return false
  end

  local items = {}
  for _, group_name in ipairs(sorted_keys(spec.groups)) do
    items[#items + 1] = { kind = "group", label = group_name, name = group_name, node = spec.groups[group_name] }
  end
  items[#items + 1] = { kind = "reset", label = "Reset language overrides" }
  vim.ui.select(items, {
    prompt = "Distill groups for " .. filetype,
    format_item = function(item)
      if item.kind == "reset" then
        return item.label
      end
      local value = state(filetype, item.node, { item.name })
      return ("[%s] %s"):format(value, item.label)
    end,
  }, function(item)
    if not item then
      return
    end
    if item.kind == "reset" then
      config.reset_groups(filetype)
      refresh_visible()
      M.open(bufnr)
    else
      open_group_menu(bufnr, filetype, item.name, item.node)
    end
  end)
  return true
end

return M
