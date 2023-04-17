-- Search for matches.
-- We convert syntax tree to treesitter's query DSL, actual searching is done by treesitter.

local ts = vim.treesitter
local parsers = require "nvim-treesitter.parsers"
local utils = require "ssr.utils"
local wildcard_prefix = require("ssr.parse").wildcard_prefix
local ExtmarkRange = require("ssr.replace").ExtmarkRange

local M = {}

---@class Match
---@field range ExtmarkRange
---@field captures ExtmarkRange[]
local Match = {}

---@param range ExtmarkRange
---@param captures table<string, ExtmarkRange>
---@return Match
function Match:new(range, captures)
  return setmetatable({
    range = range,
    captures = captures,
  }, self)
end

-- Build a TS sexpr represting the node.
---@param node userdata
---@param source string
---@return string, table<string, number>
local function build_sexpr(node, source)
  local wildcards = {}
  local next_idx = 1

  -- This function is more strict than `tsnode:sexpr()` by also requiring leaf nodes to match text.
  local function build(node)
    local text = ts.get_node_text(node, source)

    -- Special identifier __ssr_var_name is a named wildcard.
    local var = text:match("^" .. wildcard_prefix .. "([_%a%d]+)$")
    if var then
      wildcards[var] = next_idx
      next_idx = next_idx + 1
      return "(_) @" .. var
    end

    -- Leaf nodes (keyword, identifier, literal and symbol) should match text.
    if node:named_child_count() == 0 then
      local sexpr =
        string.format("(%s) @_%d (#eq? @_%d %s)", node:type(), next_idx, next_idx, utils.to_ts_query_str(text))
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
        sexpr = sexpr .. string.format(" %s: %s", name, utils.to_ts_query_str(child:type()))
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
  return sexpr, wildcards
end

---@param buf buffer
---@param node userdata
---@param source string
---@return Match[]
function M.search(buf, node, source, ns)
  local sexpr, wildcards = build_sexpr(node, source)
  local parse_query = ts.query.parse or ts.parse_query
  local query = parse_query(parsers.get_buf_lang(buf), sexpr)
  local matches = {}
  local root = utils.get_root(buf)
  for _, nodes in query:iter_matches(root, buf, 0, -1) do
    local captures = {}
    for var, idx in pairs(wildcards) do
      captures[var] = ExtmarkRange:new(buf, nodes[idx], ns)
    end
    local match = Match:new(ExtmarkRange:new(buf, nodes[#nodes], ns), captures)
    table.insert(matches, match)
  end

  -- Sort matches from
  --  buffer top to bottom, to make goto next/prev match intuitive
  --  inner to outer for recursive matches, to make replacing correct
  table.sort(matches, function(match1, match2)
    local start_row1, start_col1, end_row1, end_col1 = match1.range:get(buf)
    local start_row2, start_col2, end_row2, end_col2 = match2.range:get(buf)
    if end_row1 < start_row2 or (end_row1 == start_row2 and end_col1 <= start_col2) then
      return true
    end
    return (start_row1 > start_row2 or (start_row1 == start_row2 and start_col1 > start_col2))
      and (end_row1 < end_row2 or (end_row1 == end_row2 and end_col1 <= end_col2))
  end)

  return matches
end

return M
