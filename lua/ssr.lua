local api = vim.api
local ts = vim.treesitter
local fn = vim.fn
local keymap = vim.keymap
local highlight = vim.highlight
local parsers = require "nvim-treesitter.parsers"
local ParseContext = require("ssr.parse").ParseContext
local search = require("ssr.search").search
local replace = require("ssr.search").replace
local u = require "ssr.utils"

local M = {}

---@class Config
local config = {
  border = "rounded",
  min_width = 50,
  min_height = 5,
  max_width = 120,
  max_height = 25,
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

---@class Ui
---@field ns number
---@field cur_search_ns number
---@field augroup number
---@field ui_buf buffer
---@field extmarks {status: number, search: number, replace: number}
---@field origin_win window
---@field lang string
---@field parse_context ParseContext
---@field buf_matches table<buffer, Match[]>
local Ui = {}

---@return Ui?
function Ui.new()
  local self = setmetatable({}, { __index = Ui })

  self.origin_win = api.nvim_get_current_win()
  local origin_buf = api.nvim_win_get_buf(self.origin_win)
  self.lang = parsers.get_buf_lang(origin_buf)
  if not parsers.has_parser(self.lang) then
    return u.notify("Treesitter parser not found, please try to install it with :TSInstall " .. self.lang)
  end
  local origin_node = u.node_for_range(origin_buf, u.get_selection(self.origin_win))
  local parse_context = ParseContext.new(origin_buf, origin_node)
  if not parse_context then
    return u.notify "Can't find a proper context to parse the pattern"
  end
  self.parse_context = parse_context

  self.buf_matches = {}
  self.ns = api.nvim_create_namespace("ssr_" .. self.origin_win) -- TODO
  self.cur_search_ns = api.nvim_create_namespace("ssr_cur_match_" .. self.origin_win)
  self.augroup = api.nvim_create_augroup("ssr_augroup_" .. self.origin_win, {})

  -- Init ui buffer
  self.ui_buf = api.nvim_create_buf(false, true)
  vim.bo[self.ui_buf].bufhidden = "wipe"
  vim.bo[self.ui_buf].filetype = "ssr"

  local placeholder = ts.get_node_text(origin_node, origin_buf)
  placeholder = "\n\n" .. placeholder .. "\n\n"
  placeholder = vim.split(placeholder, "\n")
  u.remove_indent(placeholder, u.get_indent(origin_buf, origin_node:start()))
  api.nvim_buf_set_lines(self.ui_buf, 0, -1, true, placeholder)
  -- Enable syntax highlights
  ts.start(self.ui_buf, self.lang)

  local function virt_text(row, text)
    return api.nvim_buf_set_extmark(self.ui_buf, self.ns, row, 0, { virt_text = text, virt_text_pos = "overlay" })
  end
  self.extmarks = {
    status = virt_text(0, { { "[SSR]", "Comment" }, { " (Press ? for help)", "Comment" } }),
    search = virt_text(1, { { "SEARCH:", "String" } }),
    replace = virt_text(#placeholder - 2, { { "REPLACE:", "String" } }),
  }

  local function map(key, func)
    keymap.set("n", key, function()
      func(self)
    end, { buffer = self.ui_buf, nowait = true })
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

  -- Open float window
  local width, height = u.get_win_size(placeholder, config)
  local win = api.nvim_open_win(self.ui_buf, true, {
    relative = "win",
    anchor = "NE",
    row = 1,
    col = api.nvim_win_get_width(0) - 1,
    style = "minimal",
    border = config.border,
    width = width,
    height = height,
  })
  u.set_cursor(win, 2, 0)
  fn.matchadd("Title", [[$\w\+]])

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.ui_buf,
    callback = function()
      local lines = api.nvim_buf_get_lines(self.ui_buf, 0, -1, true)
      local width, height = u.get_win_size(lines, config)
      if api.nvim_win_get_width(win) ~= width then
        api.nvim_win_set_width(win, width)
      end
      if api.nvim_win_get_height(win) ~= height then
        api.nvim_win_set_height(win, height)
      end
      self:search()
    end,
  })

  -- SSR window is bound to the original window (not buffer!).
  -- Re-search in every buffer shows up in original window.
  api.nvim_create_autocmd("BufWinEnter", {
    group = self.augroup,
    callback = function(event)
      -- Not shows in the original window
      if event.buf ~= api.nvim_win_get_buf(self.origin_win) then
        return
      end
      self:search()
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    buffer = self.ui_buf,
    callback = function()
      for buf in ipairs(self.buf_matches) do
        api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
        api.nvim_buf_clear_namespace(buf, self.cur_search_ns, 0, -1)
      end
      api.nvim_clear_autocmds { group = self.augroup }
    end,
  })

  return self
end

function Ui:search()
  local pattern = self:get_input()
  local buf = api.nvim_win_get_buf(self.origin_win)
  self.buf_matches[buf] = {}
  api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, self.cur_search_ns, 0, -1)

  local start = vim.loop.hrtime()
  local node, source = self.parse_context:parse(pattern)
  if node:has_error() then
    return self:set_status "Error"
  end
  self.buf_matches[buf] = search(buf, node, source, self.ns)
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  for _, match in ipairs(self.buf_matches[buf]) do
    local start_row, start_col, end_row, end_col = match.range:get()
    highlight.range(buf, self.ns, "Search", { start_row, start_col }, { end_row, end_col }, {})
  end
  self:set_status(string.format("%d found in %dms", #self.buf_matches[buf], elapsed))
end

function Ui:next_match_idx()
  local cursor_row, cursor_col = u.get_cursor(self.origin_win)
  local buf = api.nvim_win_get_buf(self.origin_win)
  for idx, matches in pairs(self.buf_matches[buf]) do
    local start_row, start_col = matches.range:get()
    if start_row > cursor_row or (start_row == cursor_row and start_col > cursor_col) then
      return idx
    end
  end
  return 1
end

function Ui:prev_match_idx()
  local cursor_row, cursor_col = u.get_cursor(self.origin_win)
  local buf = api.nvim_win_get_buf(self.origin_win)
  local matches = self.buf_matches[buf]
  for idx = #matches, 1, -1 do
    local start_row, start_col = matches[idx].range:get()
    if start_row < cursor_row or (start_row == cursor_row and start_col < cursor_col) then
      return idx
    end
  end
  return #matches
end

function Ui:goto_match(match_idx)
  local buf = api.nvim_win_get_buf(self.origin_win)
  api.nvim_buf_clear_namespace(buf, self.cur_search_ns, 0, -1)
  local matches = self.buf_matches[buf]
  local start_row, start_col, end_row, end_col = matches[match_idx].range:get()
  u.set_cursor(self.origin_win, start_row, start_col)
  highlight.range(
    buf,
    self.cur_search_ns,
    "CurSearch",
    { start_row, start_col },
    { end_row, end_col },
    { priority = vim.highlight.priorities.user + 100 }
  )
  api.nvim_buf_set_extmark(buf, self.cur_search_ns, start_row, start_col, {
    virt_text_pos = "eol",
    virt_text = { { string.format("[%d/%d]", match_idx, #matches), "DiagnosticVirtualTextInfo" } },
  })
end

function Ui:replace_all()
  self:search()
  local buf = api.nvim_win_get_buf(self.origin_win)
  local matches = self.buf_matches[buf]
  if #matches == 0 then
    return self:set_status "pattern not found"
  end
  local _, template = self:get_input()
  local start = vim.loop.hrtime()
  for _, match in ipairs(matches) do
    replace(buf, match, template)
  end
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  self:set_status(string.format("%d replaced in %dms", #matches, elapsed))
end

function Ui:replace_confirm()
  self:search()
  local buf = api.nvim_win_get_buf(self.origin_win)
  vim.bo[buf].bufhidden = "hide"
  local matches = self.buf_matches[buf]
  if #matches == 0 then
    return self:set_status "pattern not found"
  end

  local confirm_buf = api.nvim_create_buf(false, true)
  local choices = {
    "• Yes",
    "• No",
    "──────────────",
    "• All",
    "• Quit",
    "• Last replace",
  }
  local separator_idx = 3
  api.nvim_buf_set_lines(confirm_buf, 0, -1, true, choices)
  for idx = 0, #choices - 1 do
    if idx + 1 ~= separator_idx then
      api.nvim_buf_set_extmark(confirm_buf, self.ns, idx, 4, { hl_group = "Underlined", end_row = idx, end_col = 5 })
    end
  end

  local function open_confirm_win(match_idx)
    self:goto_match(match_idx)
    local _, _, end_row, end_col = matches[match_idx].range:get()
    local cfg = {
      relative = "win",
      win = self.origin_win,
      bufpos = { end_row, end_col },
      style = "minimal",
      border = config.border,
      width = 14,
      height = 6,
    }
    if vim.fn.has "nvim-0.9" == 1 then
      cfg.title = "Replace?"
      cfg.title_pos = "center"
    end
    confirm_win = api.nvim_open_win(confirm_buf, true, cfg)
  end

  -- prevent accidental attempt to make a selection with <CR>
  keymap.set("n", "<CR>", "<Nop>", { buffer = confirm_buf })

  local function map(key, func)
    keymap.set("n", key, function()
      func()
      api.nvim_win_close(confirm_win, false)
      if match_idx <= #self.matches then
        open_confirm_win()
      else
        api.nvim_buf_delete(confirm_buf, {})
        api.nvim_buf_clear_namespace(self.origin_buf, self.cur_match_ns, 0, -1)
      end
      self:set_status(string.format("%d/%d replaced", replaced, #self.matches))
    end, { buffer = confirm_buf, nowait = true })
  end

  map("y", function()
    replace(self.origin_buf, self.matches[match_idx], template)
    replaced = replaced + 1
    match_idx = match_idx + 1
  end)

  map("n", function()
    match_idx = match_idx + 1
  end)

  map("a", function()
    for i = match_idx, #self.matches do
      replace(self.origin_buf, self.matches[i], template)
    end
    replaced = replaced + #self.matches + 1 - match_idx
    match_idx = #self.matches + 1
  end)

  map("q", function()
    match_idx = #self.matches + 1
  end)

  map("<Esc>", function()
    match_idx = #self.matches + 1
  end)

  map("<C-[>", function()
    match_idx = #self.matches + 1
  end)

  map("l", function()
    replace(self.origin_buf, self.matches[match_idx], template)
    replaced = replaced + 1
    match_idx = #self.matches + 1
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
  local pattern_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.extmarks.search, {})[1]
  local template_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.extmarks.replace, {})[1]
  local pattern = vim.trim(table.concat(lines, "\n", pattern_pos + 2, template_pos))
  local template = vim.trim(table.concat(lines, "\n", template_pos + 1, #lines))
  return pattern, template
end

function Ui:set_status(status)
  api.nvim_buf_set_extmark(self.ui_buf, self.ns, 0, 0, {
    id = self.extmarks.status,
    virt_text = {
      { "[SSR] ", "Comment" },
      { status },
      { " (Press ? for help)", "Comment" },
    },
    virt_text_pos = "overlay",
  })
end

function M.open()
  return Ui.new()
end

return M
