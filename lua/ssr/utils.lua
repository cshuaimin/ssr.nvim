local api = vim.api
local ts = vim.treesitter

local M = {}

-- Send a notification titled SSR.
---@param msg string
---@return nil
function M.notify(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "SSR" })
end

-- Get (0,0)-indexed cursor position.
---@param win integer
function M.get_cursor(win)
  local cursor = api.nvim_win_get_cursor(win)
  return cursor[1] - 1, cursor[2]
end

-- Set (0,0)-indexed cursor position.
---@param win integer
---@param row integer
---@param col integer
function M.set_cursor(win, row, col)
  api.nvim_win_set_cursor(win, { row + 1, col })
end

-- Get selected region, works in many modes.
---@param win integer
---@return integer, integer, integer, integer
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

if vim.fn.has "nvim-0.12" == 1 then
  M.get_parser = ts.get_parser
else
  function M.get_parser(...)
    local ok, parser = pcall(ts.get_parser, ...)
    if ok then
      return parser
    else
      return nil, parser
    end
  end
end

-- Get smallest node for the range.
---@param buf integer
---@param lang string
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return TSNode?, string?
function M.node_for_range(buf, lang, start_row, start_col, end_row, end_col)
  local parser = M.get_parser(buf, lang)
  if not parser then
    return nil, parser
  end
  return parser:parse()[1]:root():named_descendant_for_range(start_row, start_col, end_row, end_col)
end

---@param buf integer
---@param row integer
function M.get_indent(buf, row)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
  return line:match "^%s*"
end

---@param lines string[]
---@param indent string
function M.add_indent(lines, indent)
  for i = 2, #lines do
    lines[i] = indent .. lines[i]
  end
end

---@param lines string[]
---@param indent string
function M.remove_indent(lines, indent)
  indent = "^" .. indent
  for i, line in ipairs(lines) do
    lines[i] = line:gsub(indent, "")
  end
end

-- Escape special characters in s and quote it in double quotes.
---@param s string
function M.to_ts_query_str(s)
  s = s:gsub([[\]], [[\\]])
  s = s:gsub([["]], [[\"]])
  s = s:gsub("\n", [[\n]])
  return '"' .. s .. '"'
end

-- Compute window size to show giving lines.
---@param lines string[]
---@param config Config
---@return integer
---@return integer
function M.get_win_size(lines, config)
  ---@param i integer
  ---@param min integer
  ---@param max integer
  ---@return integer
  local function clamp(i, min, max)
    return math.min(math.max(i, min), max)
  end

  local width = 0
  for _, line in ipairs(lines) do
    if #line > width then
      width = #line
    end
  end

  width = clamp(width, config.min_width, config.max_width)
  local height = clamp(#lines, config.min_height, config.max_height)
  return width, height
end

return M
