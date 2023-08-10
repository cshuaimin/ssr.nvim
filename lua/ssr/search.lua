local api = vim.api
local ts = vim.treesitter
local parsers = require "nvim-treesitter.parsers"
local u = require "ssr.utils"

local M = {}

M.wildcard_prefix = "__ssr_var_"

---@class Match
---@field range ExtmarkRange
---@field captures ExtmarkRange[]

---@class ExtmarkRange
---@field ns number
---@field buf buffer
---@field extmark number
local ExtmarkRange = {}
M.ExtmarkRange = ExtmarkRange

---@param ns number
---@param buf buffer
---@param node TSNode
---@return ExtmarkRange
function ExtmarkRange.new(ns, buf, node)
  local start_row, start_col, end_row, end_col = node:range()
  return setmetatable({
    ns = ns,
    buf = buf,
    extmark = api.nvim_buf_set_extmark(buf, ns, start_row, start_col, {
      end_row = end_row,
      end_col = end_col,
      right_gravity = false,
      end_right_gravity = true,
    }),
  }, { __index = ExtmarkRange })
end

---@return number, number, number, number
function ExtmarkRange:get()
  local extmark = api.nvim_buf_get_extmark_by_id(self.buf, self.ns, self.extmark, { details = true })
  return extmark[1], extmark[2], extmark[3].end_row, extmark[3].end_col
end

-- Compare if two captured trees can match.
-- The check is loose because users want to match different types of node.
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
      if not tree_match(node1:child(i), node2:child(i)) then
        return false
      end
    end
    return true
  end
  return tree_match(match[pred[2]], match[pred[3]])
end, true)

-- Build a TS sexpr represting the node.
---@param node TSNode
---@param source string
---@return string, table<string, number>
local function build_sexpr(node, source)
  local wildcards = {}
  local next_idx = 1

  -- This function is more strict than `tsnode:sexpr()` by also requiring leaf nodes to match text.
  local function build(node)
    local text = ts.get_node_text(node, source)

    -- Special identifier __ssr_var_name is a named wildcard.
    -- Handle this early to make sure wildcard captures largest node.
    local var = text:match("^" .. M.wildcard_prefix .. "([_%a%d]+)$")
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
  return sexpr, wildcards
end

---@param buf buffer
---@param node TSNode
---@param source string
---@return Match[]
function M.search(buf, node, source, ns)
  local sexpr, wildcards = build_sexpr(node, source)
  local parse_query = ts.query.parse or ts.parse_query
  local query = parse_query(parsers.get_buf_lang(buf), sexpr)
  local matches = {}
  local root = parsers.get_parser(buf):parse()[1]:root()
  for _, nodes in query:iter_matches(root, buf, 0, -1) do
    local captures = {}
    for var, idx in pairs(wildcards) do
      captures[var] = ExtmarkRange.new(ns, buf, nodes[idx])
    end
    local match = { range = ExtmarkRange.new(ns, buf, nodes[#nodes]), captures = captures }
    table.insert(matches, match)
  end

  -- Sort matches from
  --  buffer top to bottom, to make goto next/prev match intuitive
  --  inner to outer for recursive matches, to make replacing correct
  table.sort(matches, function(match1, match2)
    local start_row1, start_col1, end_row1, end_col1 = match1.range:get()
    local start_row2, start_col2, end_row2, end_col2 = match2.range:get()
    if end_row1 < start_row2 or (end_row1 == start_row2 and end_col1 <= start_col2) then
      return true
    end
    return (start_row1 > start_row2 or (start_row1 == start_row2 and start_col1 > start_col2))
      and (end_row1 < end_row2 or (end_row1 == end_row2 and end_col1 <= end_col2))
  end)

  return matches
end

--- Render template and replace one match.
---@param buf buffer
---@param match Match
---@param template string
function M.replace(buf, match, template)
  -- Render templates with captured nodes.
  local replace = template:gsub("()%$([_%a%d]+)", function(pos, var)
    local start_row, start_col, end_row, end_col = match.captures[var]:get()
    local lines = api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {})
    u.remove_indent(lines, u.get_indent(buf, start_row))
    local var_lines = vim.split(template:sub(1, pos), "\n")
    local var_line = var_lines[#var_lines]
    local template_indent = var_line:match "^%s*"
    u.add_indent(lines, template_indent)
    return table.concat(lines, "\n")
  end)
  replace = vim.split(replace, "\n")
  local start_row, start_col, end_row, end_col = match.range:get()
  u.add_indent(replace, u.get_indent(buf, start_row))
  api.nvim_buf_set_text(buf, start_row, start_col, end_row, end_col, replace)
end

return M
