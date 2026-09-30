local config = require("distill.config")
local fold = require("distill.fold")

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

  local buffers, seen = {}, {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local filetype = vim.bo[bufnr].filetype
      if config.options.languages[filetype] and not seen[bufnr] then
        seen[bufnr] = true
        buffers[#buffers + 1] = bufnr
      end
    end
  end
  table.sort(buffers)
  if #buffers == 0 then
    vim.health.info("No loaded buffer uses a configured filetype")
    return
  end

  for _, bufnr in ipairs(buffers) do
    local filetype = vim.bo[bufnr].filetype
    local spec = config.options.languages[filetype]
    local name = vim.api.nvim_buf_get_name(bufnr)
    local label = name == "" and ("buffer %d"):format(bufnr) or vim.fn.fnamemodify(name, ":~:.")
    vim.health.ok(("%s uses configured filetype %q"):format(label, filetype))

    local statuses = {}
    for group, node in pairs(spec.groups or {}) do
      local counts = { enabled = 0, total = 0 }
      enabled_leaves(filetype, node, { group }, counts)
      local status = counts.enabled == 0 and "off" or (counts.enabled == counts.total and "on" or "mixed")
      statuses[#statuses + 1] = ("%s=%s"):format(group, status)
    end
    table.sort(statuses)
    vim.health.info("Effective groups: " .. table.concat(statuses, ", "))

    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if ok and parser then
      vim.health.ok(("Treesitter parser %q is available"):format(lang))
    else
      vim.health.info(("Treesitter parser %q is unavailable; conservative line-based detection will be used"):format(lang))
    end

    local windows = fold.windows_for(bufnr)
    if #windows == 0 then
      vim.health.info("Buffer is not displayed; folding compatibility was not inspected")
    end
    for _, win in ipairs(windows) do
      local method = vim.api.nvim_get_option_value("foldmethod", { win = win })
      local expr = vim.api.nvim_get_option_value("foldexpr", { win = win }) or ""
      local recognized = fold.provider_kind(expr) ~= nil or fold.is_ours(expr)
      if method ~= "expr" and method ~= "manual" then
        vim.health.warn(("window %d uses foldmethod=%s, which Distill leaves untouched"):format(win, method))
      elseif method == "expr" and expr ~= "" and expr ~= "0" and not recognized and not config.options.base_foldexpr then
        vim.health.warn(("window %d uses an unknown foldexpr; configure base_foldexpr explicitly"):format(win))
      else
        vim.health.ok(("window %d folding configuration is composable"):format(win))
      end
    end
  end
end

return M
