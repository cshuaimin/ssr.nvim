local api = vim.api
local ts = vim.treesitter
local highlight = vim.highlight
local parsers = require "nvim-treesitter.parsers"
local Parser = require("ssr.parse").Parser
local search = require("ssr.search").search
local replace = require("ssr.replace").replace
local utils = require "ssr.utils"

local M = {}

---@class Config
local config = {
  min_width = 50,
  min_height = 5,
  keymaps = {
    close = "q",
    next_match = "n",
    prev_match = "N",
    replace_all = "<leader><cr>",
  },
}

---@param cfg Config?
function M.setup(cfg)
  if cfg then
    config = vim.tbl_deep_extend("force", config, cfg)
  end
end

local help_msg = " (Press ? for help)"

---@class Ui
---@field origin_win window
---@field origin_buf buffer
---@field ui_buf buffer
---@field ns number
---@field parser Parser
---@field status_extmark number
---@field search_extmark number
---@field replace_extmark number
---@field last_pattern string
---@field matches Match[]
local Ui = {}
Ui.__index = Ui

---@return Ui
function Ui:new()
  return setmetatable({}, self)
end

function Ui:open()
  self.origin_win = api.nvim_get_current_win()
  self.origin_buf = api.nvim_win_get_buf(self.origin_win)
  local lang = parsers.get_buf_lang(self.origin_buf)
  if not parsers.has_parser(lang) then
    return utils.notify("Treesitter parser not found, please try install it with :TSInstall " .. lang)
  end
  local origin_node = utils.node_for_range(self.origin_buf, utils.get_selection(self.origin_win))
  local parser = Parser:new(self.origin_buf, origin_node)
  if not parser then
    return
  end
  self.parser = parser
  local placeholder = ts.get_node_text(origin_node, self.origin_buf)
  placeholder = "\n\n" .. placeholder .. "\n\n"
  placeholder = vim.split(placeholder, "\n")
  utils.remove_indent(placeholder, utils.get_indent(self.origin_buf, origin_node:start()))
  self.ui_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(self.ui_buf, 0, -1, true, placeholder)
  self.ns = api.nvim_create_namespace ""

  local function set_extmark(row, text)
    return api.nvim_buf_set_extmark(self.ui_buf, self.ns, row, 0, { virt_text = text, virt_text_pos = "overlay" })
  end

  self.status_extmark = set_extmark(0, { { "[SSR]", "Comment" }, { help_msg, "Comment" } })
  self.search_extmark = set_extmark(1, { { "SEARCH:", "String" } })
  self.replace_extmark = set_extmark(#placeholder - 2, { { "REPLACE:", "String" } })

  local function method(f)
    return function()
      f(self)
    end
  end

  vim.keymap.set("n", config.keymaps.next_match, method(self.next_match), { buffer = self.ui_buf })
  vim.keymap.set("n", config.keymaps.prev_match, method(self.prev_match), { buffer = self.ui_buf })
  vim.keymap.set("n", config.keymaps.replace_all, method(self.replace), { buffer = self.ui_buf })
  vim.keymap.set("n", config.keymaps.close, function()
    vim.api.nvim_buf_delete(self.ui_buf, {})
  end, { buffer = self.ui_buf })
  vim.bo[self.ui_buf].filetype = "ssr"
  ts.start(self.ui_buf, lang)

  local function max_width(lines)
    local width = 0
    for _, line in ipairs(lines) do
      if #line > width then
        width = #line
      end
    end
    return width
  end

  local win = api.nvim_open_win(self.ui_buf, true, {
    relative = "win",
    anchor = "NE",
    row = 1,
    col = api.nvim_win_get_width(0) - 1,
    style = "minimal",
    border = "rounded",
    width = math.max(max_width(placeholder), config.min_width),
    height = math.max(#placeholder, config.min_height),
  })
  api.nvim_win_set_cursor(win, { 3, 0 })
  vim.fn.matchadd("Title", [[$\w\+]])
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = self.ui_buf,
    callback = function()
      local lines = api.nvim_buf_get_lines(self.ui_buf, 0, -1, true)
      if #lines > api.nvim_win_get_height(win) then
        api.nvim_win_set_height(win, #lines)
      end
      local width = max_width(lines)
      if width > api.nvim_win_get_width(win) then
        api.nvim_win_set_width(win, width)
      end
      self:search()
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = self.ui_buf,
    callback = function(a)
      api.nvim_buf_clear_namespace(self.origin_buf, self.ns, 0, -1)
    end,
  })
end

function Ui:search()
  local pattern = self:get_input()
  if pattern == self.last_pattern then
    return
  end
  self.last_pattern = pattern
  self.matches = {}
  api.nvim_buf_clear_namespace(self.origin_buf, self.ns, 0, -1)

  local start = vim.loop.hrtime()
  local node, source = self.parser:parse(pattern)
  if not node then
    return self:set_status "Error"
  end
  self.matches = search(self.origin_buf, node, source, self.ns)
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  for _, match in ipairs(self.matches) do
    local start_row, start_col, end_row, end_col = match.range:get(self.origin_buf)
    highlight.range(self.origin_buf, self.ns, "Search", { start_row, start_col }, { end_row, end_col }, {})
    for range in ipairs(match.captures) do
      local start_row, start_col, end_row, end_col = range:get(self.origin_buf)
      highlight.range(self.origin_buf, self.ns, "Title", { start_row, start_col }, { end_row, end_col }, {})
    end
  end
  self:set_status(string.format("%d found in %dms", #self.matches, elapsed))
end

function Ui:replace()
  if #self.matches == 0 then
    return self:set_status "pattern not found"
  end
  local _, template = self:get_input()
  local start = vim.loop.hrtime()
  replace(self.origin_buf, self.matches, template)
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  self:set_status(string.format("%d replaced in %dms", #self.matches, elapsed))
end

function Ui:get_input()
  local lines = api.nvim_buf_get_lines(self.ui_buf, 0, -1, true)
  local pattern_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.search_extmark, {})[1]
  local template_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.replace_extmark, {})[1]
  local pattern = vim.trim(table.concat(lines, "\n", pattern_pos + 2, template_pos))
  local template = vim.trim(table.concat(lines, "\n", template_pos + 1, #lines))
  return pattern, template
end

function Ui:set_status(status)
  api.nvim_buf_set_extmark(self.ui_buf, self.ns, 0, 0, {
    id = self.status_extmark,
    virt_text = {
      { "[SSR] ", "Comment" },
      { status },
      { help_msg, "Comment" },
    },
    virt_text_pos = "overlay",
  })
end

function Ui:next_match()
  local cursor_row, cursor_col = utils.get_cursor(self.origin_win)
  for _, match in ipairs(self.matches) do
    local start_row, start_col, end_row, end_col = match.range:get(self.origin_buf)
    if start_row > cursor_row or (start_row == cursor_row and start_col > cursor_col) then
      api.nvim_win_set_cursor(self.origin_win, { start_row + 1, start_col })
      highlight.range(self.origin_buf, self.ns, "CurSearch", { start_row, start_col }, { end_row, end_col }, {})
      break
    end
  end
end

function Ui:prev_match() end

function M.open()
  Ui:new():open()
end

return M
