---@class Range
---@field start_row number
---@field start_col number
---@field start_byte number TODO: remove
---@field end_row number
---@field end_col number
---@field end_byte number
local Range = {}

---@param node TSNode
---@return Range
function Range.from_node(node)
  local start_row, start_col, start_byte = node:start()
  local end_row, end_col, end_byte = node:end_()
  return setmetatable({
    start_row = start_row,
    start_col = start_col,
    start_byte = start_byte,
    end_row = end_row,
    end_col = end_col,
    end_byte = end_byte,
  }, { __index = Range })
end

---@param other Range
---@return boolean
function Range:before(other)
  return self.end_row < other.start_row or (self.end_row == other.start_row and self.end_col <= other.start_col)
end

---@param other Range
---@return boolean
function Range:inside(other)
  return (
    (self.start_row > other.start_row or (self.start_row == other.start_row and self.start_col > other.start_col))
    and (self.end_row < other.end_row or (self.end_row == other.end_row and self.end_col <= other.end_col))
  )
end

return Range
