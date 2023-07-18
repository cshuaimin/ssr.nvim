local api = vim.api
local parsers = require "nvim-treesitter.parsers"

local M = {}

---@param msg string
---@return nil
function M.notify(msg)
  vim.notify(msg, "error", { title = "SSR" })
end

function M.get_cursor(win)
  local cursor = api.nvim_win_get_cursor(win)
  return cursor[1] - 1, cursor[2]
end

---@return number, number, number, number
function M.get_selection(win)
  local mode = api.nvim_get_mode().mode
  local cursor_row, cursor_col = M.get_cursor(win)
  if mode == "v" then
    local visual_pos = vim.fn.getpos "v"
    local start_row, start_col = visual_pos[2] - 1, visual_pos[3] - 1
    if start_row < cursor_row or (start_row == cursor_row and start_col < cursor_col) then
      return start_row, start_col, cursor_row, cursor_col + 1
    else
      return cursor_row, cursor_col, start_row, start_col + 1
    end
  elseif mode == "V" then
    local start_row = vim.fn.getpos("v")[2] - 1
    if cursor_row < start_row then
      start_row, cursor_row = cursor_row, start_row
    end
    local lines = api.nvim_buf_get_lines(0, start_row, cursor_row + 1, true)
    local start_col = #lines[1]:match "^(%s*)[^%s]"
    local end_col = #lines[#lines] - #lines[#lines]:match "[^%s](%s*)$"
    return start_row, start_col, cursor_row, end_col
  else
    return cursor_row, cursor_col, cursor_row, cursor_col
  end
end

---@param buf buffer
---@return TSNode
function M.get_root(buf)
  return parsers.get_parser(buf):parse()[1]:root()
end

---@param buf buffer
---@param start_row number
---@param start_col number
---@param end_row number
---@param end_col number
---@return TSNode
function M.node_for_range(buf, start_row, start_col, end_row, end_col)
  return M.get_root(buf):named_descendant_for_range(start_row, start_col, end_row, end_col)
end

---@param buf buffer
---@param row number
function M.get_indent(buf, row)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
  return line:match "^%s*"
end

---@param lines table
---@param indent string
function M.add_indent(lines, indent)
  for i = 2, #lines do
    lines[i] = indent .. lines[i]
  end
end

---@param lines table
---@param indent string
function M.remove_indent(lines, indent)
  indent = "^" .. indent
  for i, line in ipairs(lines) do
    lines[i] = line:gsub(indent, "")
  end
end

--- Escape special characters in s and quote it in double quotes.
---@param s string
function M.to_ts_query_str(s)
  s = s:gsub([[\]], [[\\]])
  s = s:gsub([["]], [[\"]])
  s = s:gsub("\n", [[\n]])
  return '"' .. s .. '"'
end

return M
