local api = vim.api
local utils = require "ssr.utils"

local M = {}

---@class ExtmarkRange
---@field ns number
---@field start_extmark number
---@field end_extmark number
local ExtmarkRange = {}
ExtmarkRange.__index = ExtmarkRange
M.ExtmarkRange = ExtmarkRange

---@param buf buffer
---@param node userdata
---@param ns number
---@return ExtmarkRange
function ExtmarkRange:new(buf, node, ns)
  local start_row, start_col, end_row, end_col = node:range()
  local start_extmark = api.nvim_buf_set_extmark(buf, ns, start_row, start_col, {
    right_gravity = false,
  })
  local end_extmark = api.nvim_buf_set_extmark(buf, ns, end_row, end_col, {})
  return setmetatable({
    ns = ns,
    start_extmark = start_extmark,
    end_extmark = end_extmark,
  }, self)
end

---@param buf buffer
---@return number, number, number, number
function ExtmarkRange:get(buf)
  local start = api.nvim_buf_get_extmark_by_id(buf, self.ns, self.start_extmark, {})
  local end_ = api.nvim_buf_get_extmark_by_id(buf, self.ns, self.end_extmark, {})
  return start[1], start[2], end_[1], end_[2]
end

--- Render template and replace one match.
---@param buf buffer
---@param match Match
---@param template string
function M.replace(buf, match, template)
  -- Render templates with captured nodes.
  local replace = template:gsub("()%$([_%a%d]+)", function(pos, var)
    local start_row, start_col, end_row, end_col = match.captures[var]:get(buf)
    local lines = api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {})
    utils.remove_indent(lines, utils.get_indent(buf, start_row))
    local var_lines = vim.split(template:sub(1, pos), "\n")
    local var_line = var_lines[#var_lines]
    local template_indent = var_line:match "^%s*"
    utils.add_indent(lines, template_indent)
    return table.concat(lines, "\n")
  end)
  replace = vim.split(replace, "\n")
  local start_row, start_col, end_row, end_col = match.range:get(buf)
  utils.add_indent(replace, utils.get_indent(buf, start_row))
  api.nvim_buf_set_text(buf, start_row, start_col, end_row, end_col, replace)
end

return M
