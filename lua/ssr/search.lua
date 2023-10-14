local ts = vim.treesitter
local Range = require "ssr.range"
local u = require "ssr.utils"

-- Compare if two captured trees can match.
-- The check is loose because we want to match different types of node.
-- e.g. converting `{ foo: foo }` to shorthand `{ foo }`.
ts.query.add_predicate("ssr-tree-match?", function(match, _pattern, buf, pred)
  ---@param node1 TSNode
  ---@param node2 TSNode
  ---@return boolean
  local function tree_match(node1, node2)
    if node1:named() ~= node2:named() then
      return false
    end
    if node1:child_count() == 0 or node2:child_count() == 0 then
      return ts.get_node_text(node1, buf) == ts.get_node_text(node2, buf)
    end
    if node1:child_count() ~= node2:child_count() then
      return false
    end
    for i = 0, node1:child_count() - 1 do
      if
        not tree_match(node1:child(i) --[[@as TSNode]], node2:child(i) --[[@as TSNode]])
      then
        return false
      end
    end
    return true
  end
  return tree_match(match[pred[2]], match[pred[3]])
end, { force = true })

-- Build a TS sexpr represting the node.
-- This function is more strict than `TSNode:sexpr()` by also requiring leaf nodes to match text.
---@param node TSNode
---@param source string
---@return string sexpr
---@return table<string, number> wildcards
---@return string rough_regex
local function build_sexpr(node, source)
  ---@type table<string, number>
  local wildcards = {}
  local rough_regex = ""
  local next_idx = 1

  ---@param node TSNode
  ---@return string
  local function build(node)
    local text = ts.get_node_text(node, source)

    -- Special identifier __ssr_var_name is a named wildcard.
    -- Handle this early to make sure wildcard captures the largest node.
    local var = text:match("^" .. u.wildcard_prefix .. "([_%a%d]+)$")
    if var then
      if not wildcards[var] then
        wildcards[var] = next_idx
        next_idx = next_idx + 1
        return "(_) @" .. var
      else
        -- Same wildcard should match the same subtree.
        local sexpr = string.format("(_) @_%d (#ssr-tree-match? @_%d @%s)", next_idx, next_idx, var)
        next_idx = next_idx + 1
        return sexpr
      end
    end

    -- Leaf nodes (keyword, identifier, literal and symbol) should match text.
    if node:named_child_count() == 0 then
      if #text > #rough_regex then -- TODO build an actual regex
        rough_regex = text
      end
      local sexpr = string.format("(%s) @_%d (#eq? @_%d %s)", node:type(), next_idx, next_idx, u.to_ts_query_str(text))
      next_idx = next_idx + 1
      return sexpr
    end

    -- Normal nodes
    local sexpr = "(" .. node:type()
    local add_anchor = false
    for child, name in node:iter_children() do
      -- Imagine using Rust's match on (name, child:named()).
      if name and child:named() then
        sexpr = sexpr .. string.format(" %s: %s", name, build(child))
      elseif name and not child:named() then
        sexpr = sexpr .. string.format(" %s: %s", name, u.to_ts_query_str(child:type()))
      elseif not name and child:named() then
        -- Pin child position with anchor `.`
        sexpr = string.format(" %s . %s", sexpr, build(child))
        add_anchor = true
      else
        -- Ignore commas and parentheses
      end
    end
    if add_anchor then
      sexpr = sexpr .. " ."
    end
    sexpr = sexpr .. ")"
    return sexpr
  end

  local sexpr = string.format("(%s) @all", build(node))
  rough_regex = u.regex_escape(rough_regex)
  return sexpr, wildcards, rough_regex
end

---@class Match
---@field range Range
---@field captures table<string, Range>

---@class Searcher
---@field lang string
---@field query vim.treesitter.Query
---@field wildcards table<string, number>
---@field rough_regex string
local Searcher = {}

---@param lang string
---@param pattern string
---@param parse_context ParseContext
---@return Searcher?
function Searcher.new(lang, pattern, parse_context)
  local node, source = parse_context:parse(pattern)
  if node:has_error() then
    return
  end
  local sexpr, wildcards, rough_regex = build_sexpr(node, source)
  local parse_query = ts.query.parse or ts.parse_query
  local query = parse_query(lang, sexpr)
  return setmetatable({
    lang = lang,
    query = query,
    wildcards = wildcards,
    rough_regex = rough_regex,
  }, { __index = Searcher })
end

---@param file File
---@return Match[]
function Searcher:search(file)
  local matches = {}
  file.tree:for_each_tree(function(tree, lang_tree) -- must called :parse(true)
    if lang_tree:lang() ~= self.lang then
      return
    end
    for _, nodes in self.query:iter_matches(tree:root(), file.source, 0, -1) do
      local range = Range.from_node(nodes[#nodes])
      local captures = {}
      for var, idx in pairs(self.wildcards) do
        captures[var] = Range.from_node(nodes[idx])
      end
      table.insert(matches, { range = range, captures = captures })
    end
  end)

  -- Sort matches from
  --  buffer top to bottom, to make goto next/prev match intuitive
  --  inner to outer for recursive matches, to make replacing correct
  ---@param match1 Match
  ---@param match2 Match
  ---@return boolean
  table.sort(matches, function(match1, match2)
    if match1.range:before(match2.range) then
      return true
    end
    return match1.range:inside(match2.range)
  end)
  return matches
end

return Searcher
