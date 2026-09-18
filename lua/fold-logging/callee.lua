-- Callee extraction: given a Treesitter node that `call_node_types` selected,
-- return the text of what is being called (e.g. "logger.info", "std::cout",
-- "$this->logger->info"), or nil if the node is not a call-like construct.
--
-- Grammars disagree on how a call is shaped, so `default` covers the common
-- layouts and a spec can set `callee = function(node, bufnr)` for the odd ones
-- (see `cpp` and `dart`).

local M = {}

local function text_of(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

-- Source text between two positions with all whitespace removed, so a callee
-- split across lines (`logger\n  .info(...)`) still matches its patterns.
local function range_text(bufnr, sr, sc, er, ec)
  local chunks = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {})
  return (table.concat(chunks, ""):gsub("%s+", ""))
end

-- Handles the layouts shared by most grammars:
--   * `function` / `macro` field  (Python, Go, JS/TS, C++, Rust, Zig, PHP functions)
--   * `name` / `method` field with the receiver as a separate child
--     (Java method_invocation, Ruby call, PHP member/scoped calls, Lua
--     function_call); the callee is everything from the start of the node up to
--     the end of that field, which keeps the receiver and separator intact
--   * otherwise the first named child (Swift call_expression)
function M.default(node, bufnr)
  local fn = node:field("function")[1] or node:field("macro")[1]
  if fn then
    return text_of(fn, bufnr)
  end
  local name = node:field("method")[1] or node:field("name")[1]
  if name then
    local sr, sc = node:start()
    local er, ec = name:end_()
    return range_text(bufnr, sr, sc, er, ec)
  end
  local first = node:named_child(0)
  return first and text_of(first, bufnr) or nil
end

-- C++: ordinary calls plus stream-style logging, where the "call" is a chain of
-- `<<` whose leftmost operand names the sink: `std::cout << x`,
-- `LOG(INFO) << x` (callee "LOG"), `qDebug() << x` (callee "qDebug").
function M.cpp(node, bufnr)
  if node:type() ~= "binary_expression" then
    return M.default(node, bufnr)
  end
  local op = node:field("operator")[1]
  if not op or text_of(op, bufnr) ~= "<<" then
    return nil
  end
  local lhs = node
  while lhs and lhs:type() == "binary_expression" do
    lhs = lhs:field("left")[1]
  end
  if not lhs then
    return nil
  end
  if lhs:type() == "call_expression" then
    lhs = lhs:field("function")[1] or lhs
  end
  return text_of(lhs, bufnr)
end

-- Dart: the grammar has no call node. `logger.i('x');` is an
-- `expression_statement` whose children are the target (`logger`), member
-- selectors (`.i`) and finally a selector holding the `argument_part`. The
-- callee is everything before the first argument selector.
function M.dart(node, bufnr)
  local named = {}
  for child in node:iter_children() do
    if child:named() then
      named[#named + 1] = child
    end
  end
  for i, child in ipairs(named) do
    local first = child:type() == "selector" and child:child(0)
    if first and first:type() == "argument_part" then
      if i == 1 then
        return nil
      end
      local sr, sc = named[1]:start()
      local er, ec = named[i - 1]:end_()
      return range_text(bufnr, sr, sc, er, ec)
    end
  end
  return nil
end

return M
