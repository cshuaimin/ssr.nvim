local api = vim.api
local u = require "ssr.utils"

---@class ssr.Range
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer
local Range = {}

---@param node TSNode
---@return ssr.Range
function Range.from_node(node)
  local start_row, start_col, end_row, end_col = node:range()
  return setmetatable({
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }, { __index = Range })
end

---@param other ssr.Range
---@return boolean
function Range:before(other)
  return self.end_row < other.start_row or (self.end_row == other.start_row and self.end_col <= other.start_col)
end

---@param other ssr.Range
---@return boolean
function Range:inside(other)
  return (
    (self.start_row > other.start_row or (self.start_row == other.start_row and self.start_col > other.start_col))
    and (self.end_row < other.end_row or (self.end_row == other.end_row and self.end_col <= other.end_col))
  )
end

-- Extmark-based ranges automatically adjust as buffer contents change.
---@param buf integer
---@return integer
function Range:to_extmark(buf)
  return api.nvim_buf_set_extmark(buf, u.namespace, self.start_row, self.start_col, {
    end_row = self.end_row,
    end_col = self.end_col,
    right_gravity = false,
    end_right_gravity = true,
  })
end

return Range
