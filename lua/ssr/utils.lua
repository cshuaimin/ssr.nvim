local api = vim.api
local ts = vim.treesitter
local config = require "ssr.config"

local M = {}

M.wildcard_prefix = "__ssr_var_"
M.namespace = api.nvim_create_namespace "ssr_ns"
M.cur_search_ns = api.nvim_create_namespace "ssr_cur_search_ns"
M.augroup = api.nvim_create_augroup("ssr_augroup", {})

-- Send a notification titled SSR.
---@param msg string
---@return nil
function M.notify(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "SSR" })
end

-- Get (0,0)-indexed cursor position.
---@param win window
function M.get_cursor(win)
  local cursor = api.nvim_win_get_cursor(win)
  return cursor[1] - 1, cursor[2]
end

-- Set (0,0)-indexed cursor position.
---@param win window
---@param row integer
---@param col integer
function M.set_cursor(win, row, col)
  api.nvim_win_set_cursor(win, { row + 1, col })
end

-- Get selected region, works in many modes.
---@param win window
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

-- Get smallest node for the range.
---@param buf buffer
---@param lang string
---@param start_row number
---@param start_col number
---@param end_row number
---@param end_col number
---@return TSNode?
function M.node_for_range(buf, lang, start_row, start_col, end_row, end_col)
  local has_parser, parser = pcall(ts.get_parser, buf, lang)
  if has_parser then
    return parser:parse()[1]:root():named_descendant_for_range(start_row, start_col, end_row, end_col)
  end
end

---@param buf buffer
---@param row number
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
---@return number
---@return number
function M.get_win_size(lines)
  ---@param i number
  ---@param min number
  ---@param max number
  ---@return number
  local function clamp(i, min, max)
    return math.min(math.max(i, min), max)
  end

  local width = 0
  for _, line in ipairs(lines) do
    if #line > width then
      width = #line
    end
  end

  width = clamp(width, config.opts.min_width, config.opts.max_width)
  local height = clamp(#lines, config.opts.min_height, config.opts.max_height)
  return width, height
end

-- https://github.com/rust-lang/regex/blob/17284451f10aa06c6c42e622e3529b98513901a8/regex-syntax/src/lib.rs#L272
local regex_meta_chars = {
  ["\\"] = true,
  ["."] = true,
  ["+"] = true,
  ["*"] = true,
  ["?"] = true,
  ["("] = true,
  [")"] = true,
  ["|"] = true,
  ["["] = true,
  ["]"] = true,
  ["{"] = true,
  ["}"] = true,
  ["^"] = true,
  ["$"] = true,
  ["#"] = true,
  ["&"] = true,
  ["-"] = true,
  ["~"] = true,
}

---@param s string
---@return string
function M.regex_escape(s)
  local escaped = s:gsub(".", function(ch)
    return regex_meta_chars[ch] and "\\" .. ch or ch
  end)
  return escaped
end

---@generic T
---@param list T[]
---@param f fun(T): -1 | 0 | 1
---@return number?
function M.binary_search_by(list, f)
  local left = 1
  local right = #list + 1
  while left < right do
    local mid = math.floor((left + right) / 2)
    local cmp = f(list[mid])
    if cmp < 0 then
      left = mid + 1
    elseif cmp > 0 then
      right = mid
    else
      return mid
    end
  end
end

---@generic T
---@param list table<T>
---@param start number 0-based
---@param end_ number exclusive
---@param replacement table<T>
function M.list_replace(list, start, end_, replacement)
  for _ = start + 1, end_ do
    table.remove(list, start + 1)
  end
  for i = start + 1, start + #replacement do
    table.insert(list, i, replacement[i - start])
  end
end

return M
