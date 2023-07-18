local ts = vim.treesitter
local parsers = require "nvim-treesitter.parsers"
local utils = require "ssr.utils"

local M = {}

M.wildcard_prefix = "__ssr_var_"

---@class Parser
---@field buf buffer
---@field lang string
---@field origin_node table
---@field context table
local Parser = {}
Parser.__index = Parser
M.Parser = Parser

function Parser:get_relative_range(text)
  local lines = vim.split(text, "\n")
  local start_row = self.origin_node.start_row - self.context.start_row
  local start_col = self.origin_node.start_col
  if start_row == 0 then
    start_col = self.origin_node.start_col - self.context.start_col
  end
  local end_row = start_row + #lines - 1
  local end_col = #lines[#lines]
  if end_row == start_row then
    end_col = end_col + start_col
  end
  return start_row, start_col, end_row, end_col
end

---@param origin_node TSNode
---@param buf buffer
---@return Parser?
function Parser:new(buf, origin_node)
  if origin_node:has_error() then
    return utils.notify "You have syntax errors in selected node"
  end
  local origin_start_row, origin_start_col, origin_start_byte = origin_node:start()
  local _, _, origin_end_byte = origin_node:end_()
  local o = setmetatable({
    buf = buf,
    lang = parsers.get_buf_lang(buf),
    origin_node = {
      start_row = origin_start_row,
      start_col = origin_start_col,
    },
    context = {
      start_row = 0,
      start_col = 0,
      before = "",
      after = "",
    },
  }, self)
  local origin_text = ts.get_node_text(origin_node, buf)
  local origin_sexpr = origin_node:sexpr()
  local context = origin_node
  while context do
    o.context.start_row, o.context.start_col = context:start()
    local str = ts.get_node_text(context, buf)
    local root = ts.get_string_parser(str, o.lang):parse()[1]:root()
    local node = root:named_descendant_for_range(o:get_relative_range(origin_text))
    if node:sexpr() == origin_sexpr then
      local start_byte
      o.context.start_row, o.context.start_col, start_byte = context:start()
      o.context.before = str:sub(1, origin_start_byte - start_byte)
      o.context.after = str:sub(origin_end_byte - start_byte + 1)
      break
    end
    context = context:parent()
  end
  if not o.context.before then
    return utils.notify "Can't find a proper context to parse pattern"
  end
  return o
end

-- Parse search pattern to syntax tree in proper context.
---@param pattern string
---@return TSNode?, string?
function Parser:parse(pattern)
  -- Replace named wildcard $name to identifier __ssr_var_name to avoid syntax error.
  pattern = pattern:gsub("%$([_%a%d]+)", M.wildcard_prefix .. "%1")
  local str = self.context.before .. pattern .. self.context.after
  local root = ts.get_string_parser(str, self.lang):parse()[1]:root()
  local node = root:named_descendant_for_range(self:get_relative_range(pattern))
  if not node:has_error() then
    return node, str
  end
end

return M
