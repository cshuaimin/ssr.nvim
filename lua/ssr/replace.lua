local api = vim.api
local u = require "ssr.utils"

---@class Replacer
local Replacer = {}

--- Render template and replace one match.
---@param buf buffer
---@param match Match
function Replacer:replace(buf, template, match)
  -- Render templates with captured nodes.
  local replace = template:gsub("()%$([_%a%d]+)", function(pos, var)
    local var_range = match.captures[var]
    local capture_lines =
      api.nvim_buf_get_text(buf, var_range.start_row, var_range.start_col, var_range.end_row, var_range.end_col, {})
    u.remove_indent(capture_lines, u.get_indent(buf, var_range.start_row))
    local var_lines = vim.split(template:sub(1, pos), "\n")
    local var_line = var_lines[#var_lines]
    local template_indent = var_line:match "^%s*"
    u.add_indent(capture_lines, template_indent)
    return table.concat(capture_lines, "\n")
  end)
  replace = vim.split(replace, "\n")
  local range = match.range
  u.add_indent(replace, u.get_indent(buf, range.start_row))
  api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, replace)
end

return Replacer
