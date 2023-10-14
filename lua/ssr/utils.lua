local api = vim.api
local ts = vim.treesitter
local config = require "ssr.config"

local M = {}

M.capture_prefix = "__ssr_capture_"
if not vim.is_thread() then
  M.namespace = api.nvim_create_namespace "ssr_ns"
  M.cur_search_ns = api.nvim_create_namespace "ssr_cur_search_ns"
  M.augroup = api.nvim_create_augroup("ssr_augroup", {})
end

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
---@return integer, number, number, number
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
---@param buf integer
---@param lang string
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return TSNode?
function M.node_for_range(buf, lang, start_row, start_col, end_row, end_col)
  local has_parser, parser = pcall(ts.get_parser, buf, lang)
  if has_parser then
    return parser:parse()[1]:root():named_descendant_for_range(start_row, start_col, end_row, end_col)
  end
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

-- Compute window size to show giving lines.
---@param lines string[]
---@return integer
---@return integer
function M.get_win_size(lines)
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

  width = clamp(width, config.opts.min_width, config.opts.max_width)
  local height = clamp(#lines, config.opts.min_height, config.opts.max_height)
  return width, height
end

-- Escapes all special characters in s.
-- The string returned may be safely used as a string content in a TS query.
---@param s string
function M.ts_str_escape(s)
  s = s:gsub([[\]], [[\\]])
  s = s:gsub([["]], [[\"]])
  s = s:gsub("\n", [[\n]])
  return s
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

-- Escapes all regular expression meta characters in s.
-- The string returned may be safely used as a literal in a regular expression.
---@param s string
---@return string
function M.regex_escape(s)
  local escaped = s:gsub(".", function(ch)
    return regex_meta_chars[ch] and "\\" .. ch or ch
  end)
  return escaped
end

---@generic T
---@param list table<T>
---@param start integer 0-based
---@param end_ integer exclusive
---@param replacement table<T>
function M.list_replace(list, start, end_, replacement)
  for _ = start + 1, end_ do
    table.remove(list, start + 1)
  end
  for i = start + 1, start + #replacement do
    table.insert(list, i, replacement[i - start])
  end
end

---@param s string
---@return string
function M.build_rough_regex(s)
  s = s:gsub("%$[_%a%d]+", "__SSR__")
  local list = {}
  for part in s:gmatch "[%a%d_=%+%-%*/]+" do
    table.insert(list, M.regex_escape(part))
  end
  return table.concat(list, "[^\\a\\d_]*"):gsub("__SSR__", ".+")
end

return M
