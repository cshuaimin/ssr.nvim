local api = vim.api
local ts = vim.treesitter
local fn = vim.fn
local keymap = vim.keymap
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
    replace_confirm = "<cr>",
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
---@field cur_search_ns number
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
    return utils.notify("Treesitter parser not found, please try to install it with :TSInstall " .. lang)
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
  self.cur_search_ns = api.nvim_create_namespace ""

  local function set_extmark(row, text)
    return api.nvim_buf_set_extmark(self.ui_buf, self.ns, row, 0, { virt_text = text, virt_text_pos = "overlay" })
  end

  self.status_extmark = set_extmark(0, { { "[SSR]", "Comment" }, { help_msg, "Comment" } })
  self.search_extmark = set_extmark(1, { { "SEARCH:", "String" } })
  self.replace_extmark = set_extmark(#placeholder - 2, { { "REPLACE:", "String" } })

  local function map(key, func)
    keymap.set("n", key, function()
      func(self)
    end, { buffer = self.ui_buf })
  end

  map(config.keymaps.replace_confirm, self.replace_confirm)
  map(config.keymaps.replace_all, self.replace_all)
  map(config.keymaps.next_match, function()
    self:goto_match(self:next_match_idx())
  end)
  map(config.keymaps.prev_match, function()
    self:goto_match(self:prev_match_idx())
  end)
  map(config.keymaps.close, function()
    api.nvim_buf_delete(self.ui_buf, {})
  end)

  -- Remap n/N in original buffer too.
  keymap.set("n", "n", function()
    self:goto_match(self:next_match_idx())
  end, { buffer = self.origin_buf })
  keymap.set("n", "N", function()
    self:goto_match(self:prev_match_idx())
  end, { buffer = self.origin_buf })

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
  fn.matchadd("Title", [[$\w\+]])
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
      api.nvim_buf_clear_namespace(self.origin_buf, self.cur_search_ns, 0, -1)
      keymap.del("n", "n", { buffer = self.origin_buf })
      keymap.del("n", "N", { buffer = self.origin_buf })
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
  end
  self:set_status(string.format("%d found in %dms", #self.matches, elapsed))
end

function Ui:next_match_idx()
  local cursor_row, cursor_col = utils.get_cursor(self.origin_win)
  for idx in ipairs(self.matches) do
    local start_row, start_col, end_row, end_col = self.matches[idx].range:get(self.origin_buf)
    if start_row > cursor_row or (start_row == cursor_row and start_col > cursor_col) then
      return idx
    end
  end
  return 1
end

function Ui:prev_match_idx()
  local cursor_row, cursor_col = utils.get_cursor(self.origin_win)
  for idx = #self.matches, 1, -1 do
    local start_row, start_col, end_row, end_col = self.matches[idx].range:get(self.origin_buf)
    if start_row < cursor_row or (start_row == cursor_row and start_col < cursor_col) then
      return idx
    end
  end
  return #self.matches
end

function Ui:goto_match(match_idx)
  api.nvim_buf_clear_namespace(self.origin_buf, self.cur_search_ns, 0, -1)
  local start_row, start_col, end_row, end_col = self.matches[match_idx].range:get(self.origin_buf)
  api.nvim_win_set_cursor(self.origin_win, { start_row + 1, start_col })
  highlight.range(self.origin_buf, self.cur_search_ns, "CurSearch", { start_row, start_col }, { end_row, end_col }, {})
  api.nvim_buf_set_extmark(self.origin_buf, self.cur_search_ns, start_row, start_col, {
    virt_text_pos = "eol",
    virt_text = { { string.format("[%d/%d]", match_idx, #self.matches), "DiagnosticVirtualTextInfo" } },
  })
end

function Ui:replace_all()
  if #self.matches == 0 then
    return self:set_status "pattern not found"
  end
  local _, template = self:get_input()
  local start = vim.loop.hrtime()
  for _, match in ipairs(self.matches) do
    replace(self.origin_buf, match, template)
  end
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  self:set_status(string.format("%d replaced in %dms", #self.matches, elapsed))
end

function Ui:replace_confirm()
  if #self.matches == 0 then
    return self:set_status "pattern not found"
  end

  local confirm_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(confirm_buf, 0, -1, true, {
    "• Yes",
    "• No",
    "──────────────",
    "• All",
    "• Quit",
    "• Last replace",
  })

  local replaced = 0
  local next_match = 1
  local confirm_win = 0
  local _, template = self:get_input()

  local function open_confirm_win()
    local start_row, start_col = self.matches[next_match].range:get(self.origin_buf)
    api.nvim_win_set_cursor(self.origin_win, { start_row + 1, start_col })
    confirm_win = api.nvim_open_win(confirm_buf, true, {
      title = "Replace?",
      title_pos = "center",
      relative = "win",
      win = self.origin_win,
      bufpos = { start_row, start_col },
      style = "minimal",
      border = "rounded",
      width = 14,
      height = 6,
    })
  end

  local function map(key, func)
    keymap.set("n", key, function()
      func()
      api.nvim_win_close(confirm_win, false)
      if next_match <= #self.matches then
        open_confirm_win()
      else
        api.nvim_buf_delete(confirm_buf, {})
      end
      self:set_status(string.format("%d/%d replaced", replaced, #self.matches))
    end, { buffer = confirm_buf, nowait = true })
  end

  map("y", function()
    replace(self.origin_buf, self.matches[next_match], template)
    replaced = replaced + 1
    next_match = next_match + 1
  end)

  map("n", function()
    next_match = next_match + 1
  end)

  map("a", function()
    for i = next_match, #self.matches do
      replace(self.origin_buf, self.matches[i], template)
    end
    replaced = replaced + #self.matches + 1 - next_match
    next_match = #self.matches + 1
  end)

  map("q", function()
    next_match = #self.matches + 1
  end)

  map("<Esc>", function()
    next_match = #self.matches + 1
  end)

  map("<C-[>", function()
    next_match = #self.matches + 1
  end)

  map("l", function()
    replace(self.origin_buf, self.matches[next_match], template)
    replaced = replaced + 1
    next_match = #self.matches + 1
  end)

  local function origin_win_map(key)
    vim.keymap.set("n", key, function()
      fn.win_execute(self.origin_win, string.format('execute "normal! \\%s"', key))
    end, { buffer = confirm_buf })
  end

  origin_win_map "<C-e>"
  origin_win_map "<C-y>"
  origin_win_map "<C-u>"
  origin_win_map "<C-d>"
  origin_win_map "<C-f>"
  origin_win_map "<C-b>"

  self:set_status(string.format("0/%d replaced", #self.matches))
  open_confirm_win()
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

function M.open()
  Ui:new():open()
end

return M
