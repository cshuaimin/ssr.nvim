local api = vim.api
local ts = vim.treesitter
local fn = vim.fn
local keymap = vim.keymap
local highlight = vim.highlight
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
  adjust_window = true,
  keymaps = {
    close = "q",
    next_match = "n",
    prev_match = "N",
    replace_confirm = "<cr>",
    replace_all = "<leader><cr>",
  },
}

-- Set config options.
---@param cfg Config?
function M.setup(cfg)
  if cfg then
    config = vim.tbl_deep_extend("force", config, cfg)
  end
end

---@type table<window, Ui>
local win_uis = {}

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
  local lang = ts.language.get_lang(vim.bo[origin_buf].filetype)
  if not lang then
    return u.notify("Treesitter language not found")
  end
  self.lang = lang

  local origin_node = u.node_for_range(origin_buf, self.lang, u.get_selection(self.origin_win))
  if not origin_node then
    return u.notify("Treesitter parser not found, please try to install it with :TSInstall " .. self.lang)
  end
  if origin_node:has_error() then
    return u.notify "You have syntax errors in the selected node"
  end
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

  -- Open float window
  local width, height = u.get_win_size(placeholder, config)
  local ui_win = api.nvim_open_win(self.ui_buf, true, {
    relative = "win",
    anchor = "NE",
    row = 1,
    col = api.nvim_win_get_width(0) - 1,
    style = "minimal",
    border = config.border,
    width = width,
    height = height,
  })
  u.set_cursor(ui_win, 2, 0)
  fn.matchadd("Title", [[$\w\+]])

  map(config.keymaps.close, function()
    api.nvim_win_close(ui_win, false)
  end)

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.ui_buf,
    callback = function()
      if config.adjust_window then
        local lines = api.nvim_buf_get_lines(self.ui_buf, 0, -1, true)
        local width, height = u.get_win_size(lines, config)
        if api.nvim_win_get_width(ui_win) ~= width then
          api.nvim_win_set_width(ui_win, width)
        end
        if api.nvim_win_get_height(ui_win) ~= height then
          api.nvim_win_set_height(ui_win, height)
        end
      end
      self:search()
    end,
  })

  -- SSR window is bound to the original window (not buffer!), which is the same behavior as IDEs and browsers.
  api.nvim_create_autocmd("BufWinEnter", {
    group = self.augroup,
    callback = function(event)
      if event.buf == self.ui_buf then
        return
      end

      local win = api.nvim_get_current_win()
      if win == ui_win then
        -- Prevent accidentally opening another file in the ssr window.
        -- Adapted from neo-tree.nvim.
        vim.schedule(function()
          api.nvim_win_set_buf(ui_win, self.ui_buf)
          local name = api.nvim_buf_get_name(event.buf)
          api.nvim_win_call(self.origin_win, function()
            pcall(api.nvim_buf_delete, event.buf, {})
            if name ~= "" then
              vim.cmd.edit(name)
            end
          end)
          api.nvim_set_current_win(self.origin_win)
        end)
        return
      elseif win ~= self.origin_win then
        return
      end

      if ts.language.get_lang(vim.bo[event.buf].filetype) ~= self.lang then
        return self:set_status "N/A"
      end
      self:search()
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    buffer = self.ui_buf,
    callback = function()
      win_uis[self.origin_win] = nil
      api.nvim_clear_autocmds { group = self.augroup }
      api.nvim_buf_delete(self.ui_buf, {})
      for buf in pairs(self.buf_matches) do
        api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
        api.nvim_buf_clear_namespace(buf, self.cur_search_ns, 0, -1)
      end
    end,
  })

  win_uis[self.origin_win] = self
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
  local matches = self.buf_matches[buf]
  if #matches == 0 then
    return self:set_status "pattern not found"
  end

  local confirm_buf = api.nvim_create_buf(false, true)
  vim.bo[confirm_buf].filetype = "ssr_confirm"
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
    return api.nvim_open_win(confirm_buf, true, cfg)
  end

  local match_idx = 1
  local replaced = 0
  local cursor = 1
  local _, template = self:get_input()
  self:set_status(string.format("replacing 0/%d", #matches))

  while match_idx <= #matches do
    local confirm_win = open_confirm_win(match_idx)

    ---@type string
    local key
    while true do
      -- Draw a fake cursor because cursor is not shown correctly when blocking on `getchar()`.
      api.nvim_buf_clear_namespace(confirm_buf, self.cur_search_ns, 0, -1)
      api.nvim_buf_set_extmark(
        confirm_buf,
        self.cur_search_ns,
        cursor - 1,
        0,
        { virt_text = { { "•", "Cursor" } }, virt_text_pos = "overlay" }
      )
      api.nvim_buf_set_extmark(confirm_buf, self.cur_search_ns, cursor - 1, 0, { line_hl_group = "CursorLine" })
      vim.cmd.redraw()

      local ok, char = pcall(vim.fn.getcharstr)
      key = ok and vim.fn.keytrans(char) or ""
      if key == "j" then
        if cursor == separator_idx - 1 then -- skip separator
          cursor = separator_idx + 1
        elseif cursor == #choices then -- wrap
          cursor = 1
        else
          cursor = cursor + 1
        end
      elseif key == "k" then
        if cursor == separator_idx + 1 then -- skip separator
          cursor = separator_idx - 1
        elseif cursor == 1 then -- wrap
          cursor = #choices
        else
          cursor = cursor - 1
        end
      elseif vim.tbl_contains({ "<C-E>", "<C-Y>", "<C-U>", "<C-D>", "<C-F>", "<C-B>" }, key) then
        fn.win_execute(self.origin_win, string.format('execute "normal! \\%s"', key))
      else
        break
      end
    end

    if key == "<CR>" then
      key = ({ "y", "n", "", "a", "q", "l" })[cursor]
    end

    if key == "y" then
      replace(buf, matches[match_idx], template)
      replaced = replaced + 1
      match_idx = match_idx + 1
    elseif key == "n" then
      match_idx = match_idx + 1
    elseif key == "a" then
      for i = match_idx, #matches do
        replace(buf, matches[i], template)
      end
      replaced = replaced + #matches + 1 - match_idx
      match_idx = #matches + 1
    elseif key == "l" then
      replace(buf, matches[match_idx], template)
      replaced = replaced + 1
      match_idx = #matches + 1
    elseif key == "q" or key == "<ESC>" or key == "" then
      match_idx = #matches + 1
    end
    api.nvim_win_close(confirm_win, false)
    self:set_status(string.format("replacing %d/%d", replaced, #matches))
  end

  api.nvim_buf_delete(confirm_buf, {})
  api.nvim_buf_clear_namespace(buf, self.cur_search_ns, 0, -1)
  self:set_status(string.format("%d/%d replaced", replaced, #matches))
end

function Ui:get_input()
  local lines = api.nvim_buf_get_lines(self.ui_buf, 0, -1, true)
  local pattern_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.extmarks.search, {})[1]
  local template_pos = api.nvim_buf_get_extmark_by_id(self.ui_buf, self.ns, self.extmarks.replace, {})[1]
  local pattern = vim.trim(table.concat(lines, "\n", pattern_pos + 2, template_pos))
  local template = vim.trim(table.concat(lines, "\n", template_pos + 1, #lines))
  return pattern, template
end

---@param status string
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

---@param win window?
---@return Ui?
function Ui.from_win(win)
  if win == nil or win == 0 then
    win = api.nvim_get_current_win()
  end
  local ui = win_uis[win]
  if not ui then
    return u.notify "No open SSR window"
  end
  return ui
end

function M.open()
  return Ui.new()
end

-- Replace all matches.
function M.replace_all()
  local ui = Ui.from_win()
  if ui then
    ui:replace_all()
  end
end

-- Confirm each match.
function M.replace_confirm()
  local ui = Ui.from_win()
  if ui then
    ui:replace_confirm()
  end
end

return M
