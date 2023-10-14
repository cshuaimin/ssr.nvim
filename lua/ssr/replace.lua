local api = vim.api
local u = require "ssr.utils"

local M = {}

---@class ssr.PinnedMatch
---@field buf integer
---@field range integer
---@field captures integer[]
M.PinnedMatch = {}

-- Convert `ssr.SearchResults` to extmark-based version.
---@param matches ssr.Matches
---@return ssr.PinnedMatch[]
function M.pin_matches(matches)
  local res = {}
  for _, row in ipairs(matches) do
    local buf = row.file:load_buf()
    for _, match in ipairs(row.matches) do
      -- local pinned = { buf = buf, range = match.range:to_extmark(buf), captures = {} }
      local pinned = { buf = buf, range = require("ssr.range").to_extmark(match.range, buf), captures = {} }
      for var, range in pairs(match.captures) do
        pinned.captures[var] = require("ssr.range").to_extmark(range, buf)
      end
      table.insert(res, pinned)
    end
  end
  return res
end

---@param buf integer
---@param id integer
---@return integer, number, number, number
local function get_extmark_range(buf, id)
  local extmark = api.nvim_buf_get_extmark_by_id(buf, u.namespace, id, { details = true })
  return extmark[1], extmark[2], extmark[3].end_row, extmark[3].end_col
end

--- Render template and replace one match.
---@param match ssr.PinnedMatch
---@param template string
function M.replace(match, template)
  -- Render templates with captured nodes.
  local replacement = template:gsub("()%$([_%a%d]+)", function(pos, var)
    local start_row, start_col, end_row, end_col = get_extmark_range(match.buf, match.captures[var])
    local capture_lines = api.nvim_buf_get_text(match.buf, start_row, start_col, end_row, end_col, {})
    u.remove_indent(capture_lines, u.get_indent(match.buf, start_row))
    local var_lines = vim.split(template:sub(1, pos), "\n")
    local var_line = var_lines[#var_lines]
    local template_indent = var_line:match "^%s*"
    u.add_indent(capture_lines, template_indent)
    return table.concat(capture_lines, "\n")
  end)
  replacement = vim.split(replacement, "\n")
  local start_row, start_col, end_row, end_col = get_extmark_range(match.buf, match.range)
  u.add_indent(replacement, u.get_indent(match.buf, start_row))
  api.nvim_buf_set_text(match.buf, start_row, start_col, end_row, end_col, replacement)
end

return M
