local config = require("distill.config")

local M = {}

local function enabled_leaves(filetype, node, path, counts)
  if node.patterns then
    counts.total = counts.total + 1
    if config.group_enabled(filetype, path) then
      counts.enabled = counts.enabled + 1
    end
    return
  end
  for name, child in pairs(node) do
    local child_path = vim.deepcopy(path)
    child_path[#child_path + 1] = name
    enabled_leaves(filetype, child, child_path, counts)
  end
end

function M.check()
  vim.health.start("distill.nvim")
  vim.health.ok("Plugin loaded")

  if config.options.enable then
    vim.health.ok("Distill is enabled")
  else
    vim.health.info("Distill is disabled; run :DistillEnable to enable it")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local spec = config.options.languages[ft]
  if not spec then
    vim.health.info(("Current filetype %q is not configured"):format(ft))
    return
  end

  vim.health.ok(("Current filetype %q is configured"):format(ft))
  local statuses = {}
  for group, node in pairs(spec.groups or {}) do
    local counts = { enabled = 0, total = 0 }
    enabled_leaves(ft, node, { group }, counts)
    local status = counts.enabled == 0 and "off" or (counts.enabled == counts.total and "on" or "mixed")
    statuses[#statuses + 1] = ("%s=%s"):format(group, status)
  end
  table.sort(statuses)
  vim.health.info("Effective groups: " .. table.concat(statuses, ", "))
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if ok and parser then
    vim.health.ok(("Treesitter parser %q is available"):format(lang))
  else
    vim.health.info(("Treesitter parser %q is unavailable; line-based detection will be used"):format(lang))
  end

  local method = vim.wo.foldmethod
  local expr = vim.wo.foldexpr
  if method ~= "expr" and method ~= "manual" then
    vim.health.warn(("foldmethod=%s is not composable; use expr or manual"):format(method))
  elseif
    method == "expr"
    and expr ~= ""
    and expr ~= "0"
    and not expr:find("distill.fold", 1, true)
    and not expr:find("lsp", 1, true)
    and not expr:find("treesitter", 1, true)
    and not config.options.base_foldexpr
  then
    vim.health.warn("Custom foldexpr detected; configure base_foldexpr with an equivalent Lua function")
  else
    vim.health.ok("Current folding configuration is composable")
  end
end

return M
