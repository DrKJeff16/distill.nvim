local languages = require("distill.languages")

local M = {}

M.defaults = {
  -- Initial state. When false action commands are no-ops and no mappings or
  -- folding hooks are activated; `:DistillEnable` remains available.
  enable = true,

  -- Fold logging statements automatically when a supported file is opened, and
  -- fold newly added logging statements when the file is written. When false,
  -- folds are only created/closed via the commands or the Lua API.
  auto_fold = true,

  -- Fold families. A boolean controls the whole family. Replace it with a table
  -- to override subgroups or levels, e.g.
  --   output = { enabled = false, print = true }
  --   logging = { enabled = true, levels = { trace = false } }
  groups = {
    logging = true,
    output = false,
    tracing = false,
    control = false,
  },

  -- Optional per-filetype overrides with the same shape as `groups`.
  --   python = { output = { print = true, debugger = false } }
  language_groups = {},

  -- Minimum number of lines a (possibly merged) logging region must span to be
  -- folded. 1 = fold everything that qualifies, including one-line calls; 3 =
  -- only fold blocks of 3+ lines, and so on.
  min_lines = 2,

  -- Base foldexpr that produces the *general* folds (functions, classes, ...).
  -- distill composes its logging folds on top of this so it never replaces
  -- your normal folding. `nil` detects native LSP and Treesitter expressions;
  -- unknown custom expressions are left untouched. Set explicitly to a
  -- `function(lnum) -> foldexpr value` to compose a custom provider, e.g.
  --   base_foldexpr = vim.lsp.foldexpr
  base_foldexpr = nil,

  -- Normal-mode mappings for the most common actions. Set `keymaps = false`
  -- to disable them, or set an individual action to false to leave it unmapped.
  keymaps = {
    fold = "<leader>df",
    unfold = "<leader>du",
    toggle = "<leader>dt",
    refresh = "<leader>dr",
    list = "<leader>dl",
    config = "<leader>dc",
  },

  -- Per-filetype detection specs. Merged (deep) over the built-ins, so you can
  -- add new filetypes or override an existing spec's `groups`.
  languages = languages.defaults,
}

M.options = vim.deepcopy(M.defaults)
M.generation = 0

local function validate_group_tree(tree, name)
  for key, value in pairs(tree or {}) do
    if key ~= "enabled" and type(key) ~= "string" then
      error(("distill: %s keys must be strings"):format(name))
    end
    if key == "enabled" and type(value) ~= "boolean" then
      error(("distill: %s.enabled must be a boolean"):format(name))
    elseif type(value) == "table" then
      validate_group_tree(value, name .. "." .. tostring(key))
    elseif type(value) ~= "boolean" then
      error(("distill: %s.%s must be a boolean or table"):format(name, tostring(key)))
    end
  end
end

local function validate_patterns(patterns, name)
  if type(patterns) ~= "table" or #patterns == 0 then
    error(("distill: %s.patterns must be a non-empty list"):format(name))
  end
  for i, pattern in ipairs(patterns) do
    if type(pattern) ~= "string" or pattern == "" then
      error(("distill: %s.patterns[%d] must be a non-empty string"):format(name, i))
    end
  end
end

local function validate_languages(languages)
  for filetype, spec in pairs(languages) do
    local name = "languages." .. tostring(filetype)
    if type(filetype) ~= "string" or filetype == "" then
      error("distill: languages keys must be non-empty strings")
    elseif spec ~= false and type(spec) ~= "table" then
      error(("distill: %s must be false or a table"):format(name))
    elseif type(spec) == "table" then
      if type(spec.call_node_types) ~= "table" or #spec.call_node_types == 0 then
        error(("distill: %s.call_node_types must be a non-empty list"):format(name))
      end
      for i, node_type in ipairs(spec.call_node_types) do
        if type(node_type) ~= "string" or node_type == "" then
          error(("distill: %s.call_node_types[%d] must be a non-empty string"):format(name, i))
        end
      end
      if spec.callee ~= nil and type(spec.callee) ~= "function" then
        error(("distill: %s.callee must be a function"):format(name))
      end
      if spec.require_args ~= nil and type(spec.require_args) ~= "boolean" then
        error(("distill: %s.require_args must be a boolean"):format(name))
      end
      if type(spec.groups) ~= "table" then
        error(("distill: %s.groups must be a table"):format(name))
      end
      for group, subgroups in pairs(spec.groups) do
        if type(group) ~= "string" or type(subgroups) ~= "table" then
          error(("distill: %s.groups must contain named subgroup tables"):format(name))
        end
        for subgroup, levels in pairs(subgroups) do
          if type(subgroup) ~= "string" or type(levels) ~= "table" then
            error(("distill: %s.groups.%s must contain named level tables"):format(name, group))
          end
          for level, rule in pairs(levels) do
            local rule_name = ("%s.groups.%s.%s.%s"):format(name, group, subgroup, tostring(level))
            if type(level) ~= "string" or type(rule) ~= "table" then
              error(("distill: %s must be a rule table"):format(rule_name))
            end
            validate_patterns(rule.patterns, rule_name)
            if rule.require_args ~= nil and type(rule.require_args) ~= "boolean" then
              error(("distill: %s.require_args must be a boolean"):format(rule_name))
            end
            if rule.priority ~= nil and type(rule.priority) ~= "number" then
              error(("distill: %s.priority must be a number"):format(rule_name))
            end
          end
        end
      end
    end
  end
end

local function validate(opts)
  if type(opts) ~= "table" then
    error("distill: setup options must be a table")
  end

  for _, name in ipairs({ "enable", "auto_fold" }) do
    if opts[name] ~= nil and type(opts[name]) ~= "boolean" then
      error(("distill: %s must be a boolean"):format(name))
    end
  end
  if opts.min_lines ~= nil and (type(opts.min_lines) ~= "number" or opts.min_lines < 1 or opts.min_lines % 1 ~= 0) then
    error("distill: min_lines must be a positive integer")
  end
  if opts.base_foldexpr ~= nil and type(opts.base_foldexpr) ~= "function" then
    error("distill: base_foldexpr must be a function")
  end
  if opts.keymaps ~= nil and opts.keymaps ~= false and type(opts.keymaps) ~= "table" then
    error("distill: keymaps must be false or a table")
  end
  if type(opts.keymaps) == "table" then
    local valid = { fold = true, unfold = true, toggle = true, refresh = true, list = true, config = true }
    for action, mapping in pairs(opts.keymaps) do
      if not valid[action] then
        error(("distill: unknown keymap action %q"):format(action))
      end
      if mapping ~= false and (type(mapping) ~= "string" or mapping == "") then
        error(("distill: keymaps.%s must be false or a non-empty string"):format(action))
      end
    end
  end
  if opts.languages ~= nil and type(opts.languages) ~= "table" then
    error("distill: languages must be a table")
  end
  if opts.groups ~= nil and type(opts.groups) ~= "table" then
    error("distill: groups must be a table")
  end
  if opts.language_groups ~= nil and type(opts.language_groups) ~= "table" then
    error("distill: language_groups must be a table")
  end
  validate_group_tree(opts.groups, "groups")
  for filetype, groups in pairs(opts.language_groups or {}) do
    if type(filetype) ~= "string" or filetype == "" or type(groups) ~= "table" then
      error("distill: language_groups must contain per-filetype tables")
    end
    validate_group_tree(groups, "language_groups." .. filetype)
  end
end

function M.setup(opts)
  opts = opts or {}
  validate(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  validate_languages(merged.languages)
  M.options = merged
  M.generation = M.generation + 1
  return M.options
end

local function tree_override(tree, path)
  if type(tree) ~= "table" then
    return type(tree) == "boolean" and tree or nil
  end
  local node, value = tree, tree.enabled
  for _, key in ipairs(path) do
    if type(node) ~= "table" then
      return type(node) == "boolean" and node or value
    end
    node = node[key]
    if node == nil then
      return value
    elseif type(node) == "boolean" then
      value = node
    elseif type(node) == "table" and node.enabled ~= nil then
      value = node.enabled
    end
  end
  return type(node) == "boolean" and node or value
end

function M.group_enabled(filetype, path)
  local enabled = tree_override(M.options.groups, path)
  local language = tree_override(M.options.language_groups[filetype], path)
  if language ~= nil then
    enabled = language
  end
  return enabled == true
end

function M.set_group(filetype, path, enabled)
  if type(filetype) ~= "string" or filetype == "" or #path == 0 or type(enabled) ~= "boolean" then
    error("distill: set_group requires a filetype, non-empty path, and boolean value")
  end
  local node = M.options.language_groups
  node[filetype] = node[filetype] or {}
  node = node[filetype]
  for i = 1, #path - 1 do
    local key = path[i]
    if type(node[key]) ~= "table" then
      node[key] = type(node[key]) == "boolean" and { enabled = node[key] } or {}
    end
    node = node[key]
  end
  node[path[#path]] = enabled
  M.generation = M.generation + 1
end

function M.reset_groups(filetype)
  M.options.language_groups[filetype] = nil
  M.generation = M.generation + 1
end

return M
