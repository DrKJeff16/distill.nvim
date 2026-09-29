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
    if entry and not (require_args and has_no_args(node)) then
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

-- Walk forward from `start_line` counting parentheses to find the line on which
-- the call's argument list closes. Heuristic, used only without a parser.
local function balanced_end(lines, start_line)
  local depth, started = 0, false
  for j = start_line, #lines do
    for ch in lines[j]:gmatch("[%(%)]") do
      if ch == "(" then
        depth, started = depth + 1, true
      else
        depth = depth - 1
      end
    end
    if started and depth <= 0 then
      return j
    end
  end
  return start_line
end

-- Regex/line backend for when no treesitter parser is available.
function M.fallback(bufnr, spec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  for i, line in ipairs(lines) do
    -- Callee characters: identifiers plus the separators `.`, `::`, `->`, the
    -- PHP `$` sigil and the Rust macro `!` (dropped before matching).
    for name, args_start in line:gmatch("([%w_%.:>%-%$!]+)%s*%(()") do
      name = name:gsub("!$", "")
      local has_args = not line:sub(args_start):find("^%s*%)")
      local entry = matching_entry(name, spec.entries)
      if entry and not (entry.require_args and not has_args) then
        out[#out + 1] = {
          start = i,
          ["end"] = balanced_end(lines, i),
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

-- Keep only the outermost regions: drop any region fully contained in (or
-- overlapping the tail of) one that starts earlier.
local function normalize(regions)
  table.sort(regions, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a["end"] > b["end"]
  end)
  local out, last_end = {}, 0
  for _, r in ipairs(regions) do
    if r.start > last_end then
      out[#out + 1] = r
      last_end = r["end"]
    elseif r["end"] > last_end then
      last_end = r["end"]
    end
  end
  return out
end

local function effective_spec(spec, filetype)
  local entries = {}
  for group, subgroups in pairs(spec.groups or {}) do
    for subgroup, levels in pairs(subgroups) do
      for level, entry in pairs(levels) do
        if config.group_enabled(filetype, { group, subgroup, level }) then
          entries[#entries + 1] = {
            patterns = entry.patterns or {},
            require_args = entry.require_args ~= nil and entry.require_args or spec.require_args,
            group = group,
            subgroup = subgroup,
            level = level,
          }
        end
      end
    end
  end
  return {
    call_node_types = spec.call_node_types,
    entries = entries,
    callee = spec.callee,
  }
end

M._effective_spec = effective_spec

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
