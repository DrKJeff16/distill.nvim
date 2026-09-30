local config = require("distill.config")
local callee = require("distill.callee")

local M = {}

-- A detected region is `{ start = <1-based line>, ["end"] = <1-based line>, text = <callee> }`.

local function matches(text, patterns)
  if not text then
    return false
  end
  for _, pat in ipairs(patterns) do
    if text:find(pat) then
      return true
    end
  end
  return false
end

local function matching_entry(text, entries)
  for _, entry in ipairs(entries or {}) do
    if matches(text, entry.patterns) then
      return entry
    end
  end
  return nil
end

-- True for a call written with an empty argument list, e.g. `err.Error()`.
-- Grammars without an `arguments` field (macros, Ruby's paren-less calls) never
-- count as empty.
local function has_no_args(node)
  local args = node:field("arguments")[1]
  return args ~= nil and args:named_child_count() == 0
end

-- Treesitter backend. Returns a list of regions, or nil if no parser/query.
function M.treesitter(bufnr, spec, lang)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end
  local root = trees[1]:root()

  local parts = {}
  for _, nt in ipairs(spec.call_node_types or {}) do
    parts[#parts + 1] = ("(%s) @call"):format(nt)
  end
  if #parts == 0 then
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.parse, lang, table.concat(parts, "\n"))
  if not okq then
    return nil
  end

  local get_callee = spec.callee or callee.default
  local out = {}
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    local txt = get_callee(node, bufnr)
    local entry = matching_entry(txt, spec.entries)
    local require_args = entry and entry.require_args
    if entry and entry.enabled and not (require_args and has_no_args(node)) then
      local sr, _, er, ec = node:range()
      -- treesitter end position is exclusive; if it lands on column 0 the call
      -- really ends on the previous line.
      if ec == 0 and er > sr then
        er = er - 1
      end
      out[#out + 1] = {
        start = sr + 1,
        ["end"] = er + 1,
        text = vim.trim(txt or ""),
        group = entry.group,
        subgroup = entry.subgroup,
        level = entry.level,
      }
    end
  end
  return out
end

-- Replace strings and comments with spaces while preserving byte positions.
-- The fallback intentionally understands only common delimiters; uncertain
-- syntax stays invisible rather than risking a fold over executable code.
local function sanitize(lines)
  local out, block_comment, multiline_quote = {}, false, nil
  for lnum, line in ipairs(lines) do
    local chars, i, quote = {}, 1, multiline_quote
    while i <= #line do
      local pair = line:sub(i, i + 1)
      local triple = line:sub(i, i + 2)
      if block_comment then
        chars[#chars + 1] = " "
        if pair == "*/" then
          chars[#chars + 1] = " "
          block_comment, i = false, i + 2
        else
          i = i + 1
        end
      elseif quote then
        local delimiter = quote
        local width = #delimiter
        if line:sub(i, i + width - 1) == delimiter then
          chars[#chars + 1] = string.rep(" ", width)
          quote, multiline_quote, i = nil, nil, i + width
        elseif width == 1 and line:sub(i, i) == "\\" and i < #line then
          chars[#chars + 1] = "  "
          i = i + 2
        else
          chars[#chars + 1] = " "
          i = i + 1
        end
      elseif pair == "/*" then
        chars[#chars + 1] = "  "
        block_comment, i = true, i + 2
      elseif pair == "//" or pair == "--" or line:sub(i, i) == "#" then
        chars[#chars + 1] = string.rep(" ", #line - i + 1)
        i = #line + 1
      elseif triple == '"""' or triple == "'''" then
        chars[#chars + 1] = "_  "
        quote, multiline_quote, i = triple, triple, i + 3
      elseif line:sub(i, i) == '"' or line:sub(i, i) == "'" or line:sub(i, i) == "`" then
        quote = line:sub(i, i)
        multiline_quote = quote == "`" and quote or nil
        chars[#chars + 1] = "_"
        i = i + 1
      else
        chars[#chars + 1] = line:sub(i, i)
        i = i + 1
      end
    end
    if quote == '"' or quote == "'" then
      quote = nil
    end
    multiline_quote = quote
    out[lnum] = table.concat(chars)
  end
  return out
end

-- Walk forward from the matched opening parenthesis to find its closing line.
local function balanced_end(lines, start_line, args_start)
  local depth = 0
  for j = start_line, #lines do
    local from = j == start_line and math.max(1, args_start - 1) or 1
    for ch in lines[j]:sub(from):gmatch("[%(%)]") do
      if ch == "(" then
        depth = depth + 1
      else
        depth = depth - 1
      end
    end
    if depth == 0 then
      return j
    end
  end
  -- Unbalanced heuristic input is unsafe to extend across unrelated lines.
  return start_line
end

local function has_arguments(lines, start_line, args_start)
  for j = start_line, #lines do
    local from = j == start_line and args_start or 1
    local rest = lines[j]:sub(from)
    local first = rest:match("^%s*(.)")
    if first then
      return first ~= ")"
    end
  end
  return false
end

-- Regex/line backend for when no treesitter parser is available.
function M.fallback(bufnr, spec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local clean = sanitize(lines)
  local out = {}
  for i, line in ipairs(clean) do
    -- Callee characters: identifiers plus the separators `.`, `::`, `->`, the
    -- PHP `$` sigil and the Rust macro `!` (dropped before matching).
    for name, args_start in line:gmatch("([%w_%.:>%-%$!]+)%s*%(()") do
      name = name:gsub("!$", "")
      local has_args = has_arguments(clean, i, args_start)
      local entry = matching_entry(name, spec.entries)
      if entry and entry.enabled and not (entry.require_args and not has_args) then
        out[#out + 1] = {
          start = i,
          ["end"] = balanced_end(clean, i, args_start),
          text = name,
          group = entry.group,
          subgroup = entry.subgroup,
          level = entry.level,
        }
        break
      end
    end
  end
  return out
end

-- Keep outermost regions and preserve the union of partially overlapping calls.
local function normalize(regions)
  table.sort(regions, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a["end"] > b["end"]
  end)
  local out = {}
  for _, r in ipairs(regions) do
    local current = out[#out]
    if not current or r.start > current["end"] then
      out[#out + 1] = r
    elseif r["end"] > current["end"] then
      current["end"] = r["end"]
    end
  end
  return out
end

local function effective_spec(spec, filetype)
  local entries = {}
  for group, subgroups in pairs(spec.groups or {}) do
    for subgroup, levels in pairs(subgroups) do
      for level, entry in pairs(levels) do
        local require_args = spec.require_args
        if entry.require_args ~= nil then
          require_args = entry.require_args
        end
        entries[#entries + 1] = {
          patterns = entry.patterns or {},
          require_args = require_args,
          priority = entry.priority or 0,
          enabled = config.group_enabled(filetype, { group, subgroup, level }),
          group = group,
          subgroup = subgroup,
          level = level,
        }
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    local ap = table.concat({ a.group, a.subgroup, a.level }, "\0")
    local bp = table.concat({ b.group, b.subgroup, b.level }, "\0")
    return ap < bp
  end)
  return {
    call_node_types = spec.call_node_types,
    entries = entries,
    callee = spec.callee,
  }
end

M._effective_spec = effective_spec
M._normalize = normalize

-- Public: detect logging regions in `bufnr`. Returns normalized outermost
-- regions sorted by start line.
function M.detect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local spec = config.options.languages[ft]
  if not spec then
    return {}
  end
  spec = effective_spec(spec, ft)
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local regions = M.treesitter(bufnr, spec, lang)
  if not regions then
    regions = M.fallback(bufnr, spec)
  end
  return normalize(regions)
end

return M
