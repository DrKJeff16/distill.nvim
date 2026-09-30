-- Per-language detection tests. Run from the repo root with:
--   nvim --headless -u NORC -c "luafile tests/languages.lua"
--
-- Each fixture in tests/fixtures/ marks the lines that must be detected:
--   @log    detected by the default logging group
--   @print  detected only with the output group enabled
-- Every unmarked call is a negative control (e.g. `err.Error()`, `Math.log`).
--
-- A language is SKIPPED when its Treesitter parser is not installed. To test
-- parsers that live outside Neovim's runtimepath, point DISTILL_PARSERS at
-- a directory of `<lang>.so` files.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:append(root)

local config = require("distill.config")
local detect = require("distill.detect")
config.setup({})

local failures, skipped = 0, 0

local function fail(msg)
  failures = failures + 1
  print("FAIL - " .. msg)
end

local function load_parser(lang)
  local ok = pcall(vim.treesitter.language.add, lang)
  if ok and pcall(vim.treesitter.query.parse, lang, "(_) @node") then
    return true
  end
  local dir = vim.env.DISTILL_PARSERS
  if not dir then
    return false
  end
  return pcall(vim.treesitter.language.add, lang, { path = ("%s/%s.so"):format(dir, lang) })
end

local function sorted_keys(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function detected_starts(buf)
  local set = {}
  for _, r in ipairs(detect.detect(buf)) do
    set[r.start] = true
  end
  return set
end

-- filetype -> fixture
local cases = {
  { "go", "sample.go" },
  { "javascript", "sample.js" },
  { "typescript", "sample.ts" },
  { "rust", "sample.rs" },
  { "cpp", "sample.cpp" },
  { "zig", "sample.zig" },
  { "ruby", "sample.rb" },
  { "java", "sample.java" },
  { "php", "sample.php" },
  { "swift", "sample.swift" },
  { "lua", "sample.lua" },
  { "dart", "sample.dart" },
}

for _, case in ipairs(cases) do
  local ft, file = case[1], case[2]
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not load_parser(lang) then
    skipped = skipped + 1
    print(("skip - %s: no Treesitter parser for '%s'"):format(ft, lang))
  else
    local lines = vim.fn.readfile(root .. "tests/fixtures/" .. file)
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = ft
    local buf = vim.api.nvim_get_current_buf()

    local log, print_ = {}, {}
    for i, line in ipairs(lines) do
      if line:find("@log", 1, true) then
        log[i] = true
      elseif line:find("@print", 1, true) then
        print_[i] = true
      end
    end

    local function compare(label, expected)
      local got = detected_starts(buf)
      local missing, extra = {}, {}
      for l in pairs(expected) do
        if not got[l] then
          missing[l] = true
        end
      end
      for l in pairs(got) do
        if not expected[l] then
          extra[l] = true
        end
      end
      if next(missing) or next(extra) then
        fail(
          ("%s (%s): missing lines {%s}, unexpected lines {%s}"):format(
            ft,
            label,
            table.concat(sorted_keys(missing), ","),
            table.concat(sorted_keys(extra), ",")
          )
        )
      else
        print(("ok   - %s (%s): %d region(s)"):format(ft, label, #sorted_keys(expected)))
      end
    end

    -- Guard against silently testing the regex fallback instead of Treesitter.
    local spec = config.options.languages[ft]
    if detect.treesitter(buf, { call_node_types = spec.call_node_types, entries = {} }, lang) == nil then
      fail(ft .. ": Treesitter backend unavailable")
    end

    config.options.groups.output = false
    compare("output=false", log)

    config.options.groups.output = true
    compare("output=true", vim.tbl_extend("force", log, print_))
    config.options.groups.output = false
  end
end

print(("\n%d failure(s), %d skipped"):format(failures, skipped))
vim.cmd((failures == 0) and "qa!" or "cq!")
