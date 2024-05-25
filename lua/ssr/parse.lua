local ts = vim.treesitter
local wildcard_prefix = require("ssr.search").wildcard_prefix

local M = {}

---Substituts $var using the provided function, and unescapes $$.
---@param pattern string
---@param replace fun(string):string a function that takes the variable name and returns the substitution result
local function substitute_variables(pattern, replace)
  return pattern:gsub("%$(%$?[_%a%d]*)", function(match)
    if match == "" then
      -- single $, not a valid variable
      return "$"
    end
    if string.match(match, "^%$") then
      -- this is an escaped $
      return match
    end

    return replace(match)
  end)
end

---@class ParseContext
---@field lang string
---@field before string
---@field after string
---@field pad_rows integer
---@field pad_cols integer
local ParseContext = {}
ParseContext.__index = ParseContext
M.ParseContext = ParseContext

-- Create a context in which `origin_node` (and user input) will be parsed correctly.
---@param buf buffer
---@param origin_node TSNode
---@return ParseContext?
function ParseContext.new(buf, origin_node)
  local lang = ts.language.get_lang(vim.bo[buf].filetype)
  if not lang then
    return
  end
  local self = setmetatable({ lang = lang }, { __index = ParseContext })

  local origin_start_row, origin_start_col, origin_start_byte = origin_node:start()
  local _, _, origin_end_byte = origin_node:end_()
  local origin_lines = vim.split(ts.get_node_text(origin_node, buf), "\n")
  local origin_sexpr = origin_node:sexpr()
  ---@type TSNode?
  local context_node = origin_node

  -- Find an ancestor of `origin_node`
  while context_node do
    local context_text = ts.get_node_text(context_node, buf)
    local root = ts.get_string_parser(context_text, self.lang):parse()[1]:root()

    -- Get the range of `origin_text` relative to the string `context_text`.
    local context_start_row, context_start_col = context_node:start()
    local start_row = origin_start_row - context_start_row
    local start_col = origin_start_col
    if start_row == 0 then
      start_col = origin_start_col - context_start_col
    end
    local end_row = start_row + #origin_lines - 1
    local end_col = #origin_lines[#origin_lines]
    if end_row == start_row then
      end_col = end_col + start_col
    end
    local node_in_context = root:named_descendant_for_range(start_row, start_col, end_row, end_col)
    if node_in_context and node_in_context:type() == origin_node:type() and node_in_context:sexpr() == origin_sexpr then
      local context_start_byte
      self.start_row, self.start_col, context_start_byte = context_node:start()
      self.before = context_text:sub(1, origin_start_byte - context_start_byte)
      self.after = context_text:sub(origin_end_byte - context_start_byte + 1)
      self.pad_rows = start_row
      self.pad_cols = start_col
      return self
    end
    -- Try next parent
    context_node = context_node:parent()
  end
end

-- Parse search pattern to syntax tree in proper context.
---@param pattern string
---@return TSNode?, string
function ParseContext:parse(pattern)
  -- Replace named wildcard $name to identifier __ssr_var_name to avoid syntax error.
  pattern = substitute_variables(pattern, function(var) return wildcard_prefix .. var end)
  local context_text = self.before .. pattern .. self.after
  local root = ts.get_string_parser(context_text, self.lang):parse()[1]:root()
  local lines = vim.split(pattern, "\n")
  local node = root:named_descendant_for_range(self.pad_rows, self.pad_cols, self.pad_rows + #lines - 1, #lines[#lines])
  return node, context_text
end

return M
