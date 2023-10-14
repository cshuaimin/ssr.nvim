local api = vim.api
local ts = vim.treesitter
local config = require "ssr.config"
local ResultList = require "ssr.ui.result_list"
local u = require "ssr.utils"

---@class MainWin
---@field buf integer
---@field win integer
---@field origin_win integer
---@field lang string
---@field last_pattern string[]
---@field last_template string[]
---@field result_list ResultList
local MainWin = {}

function MainWin.new(lang, pattern, template, origin_win)
  local self = setmetatable({
    lang = lang,
    last_pattern = pattern,
    last_template = template,
    origin_win = origin_win,
  }, { __index = MainWin })

  self.buf = api.nvim_create_buf(false, true)
  vim.bo[self.buf].filetype = "ssr"

  local lines = self:render()
  self:open_win(u.get_win_size(lines))

  self.result_list = ResultList.new(self.buf, self.win, self.extmarks.results)

  self:setup_autocmds()
  self:setup_keymaps()

  return self
end

---@private
function MainWin:render()
  ts.stop(self.buf)
  api.nvim_buf_clear_namespace(self.buf, u.namespace, 0, -1)

  local lines = {
    "", -- [SSR]
    "```" .. self.lang, -- SEARCH:
  }
  vim.list_extend(lines, self.last_pattern)
  table.insert(lines, "") -- REPLACE:
  vim.list_extend(lines, self.last_template)
  table.insert(lines, "```") -- RESULTS:
  api.nvim_buf_set_lines(self.buf, 0, -1, true, lines)

  -- Enable syntax highlights for input area.
  local parser = ts.get_parser(self.buf, "markdown")
  parser:parse(true)
  parser:for_each_tree(function(tree, lang_tree)
    if tree:root():start() == 2 then
      ts.highlighter.new(lang_tree)
    end
  end)

  local function virt_text(row, text)
    return api.nvim_buf_set_extmark(self.buf, u.namespace, row, 0, { virt_text = text, virt_text_pos = "overlay" })
  end
  self.extmarks = {
    status = virt_text(0, { { "[SSR]", "Comment" }, { " (Press ? for help)", "Comment" } }),
    search = virt_text(1, { { "SEARCH:           ", "String" } }), -- Extra spaces to cover too long language name.
    replace = virt_text(#lines - 3, { { "REPLACE:", "String" } }),
    results = virt_text(#lines - 1, { { "RESULTS:", "String" } }),
  }

  return lines
end

---@private
function MainWin:check(lines)
  if #lines < 6 then
    return false
  end

  local function get_index(extmark)
    return api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, extmark, {})[1] + 1
  end

  return get_index(self.extmarks.status) == 1
    and lines[1] == ""
    and get_index(self.extmarks.search) == 2
    and lines[2] == "```" .. self.lang
    and lines[get_index(self.extmarks.replace)] == ""
    and lines[get_index(self.extmarks.results)] == "```"
end

---@private
function MainWin:open_win(width, height)
  self.win = api.nvim_open_win(self.buf, true, {
    relative = "editor",
    anchor = "NE",
    row = 0,
    col = vim.o.columns - 1,
    style = "minimal",
    border = config.opts.border,
    width = width,
    height = height,
  })
  vim.wo[self.win].wrap = false
  if vim.fn.has "nvim-0.10" == 1 then
    vim.wo[self.win].winfixbuf = true
  end
  u.set_cursor(self.win, 2, 0)
  vim.fn.matchadd("Title", [[$\w\+]])
end

function MainWin:on(event, func)
  api.nvim_create_autocmd(event, {
    group = u.augroup,
    buffer = self.buf,
    callback = func,
  })
end

---@private
function MainWin:setup_autocmds()
  self:on({ "TextChanged", "TextChangedI" }, function()
    local lines = api.nvim_buf_get_lines(self.buf, 0, -1, true)
    if not self:check(lines) then
      self:render()
      self.result_list.extmark = self.extmarks.results
      self.result_list:set {}
      u.set_cursor(self.win, 2, 0)
    end
    if not config.opts.adjust_window then
      return
    end
    local width, height = u.get_win_size(lines)
    if api.nvim_win_get_width(self.win) ~= width then
      api.nvim_win_set_width(self.win, width)
    end
    if api.nvim_win_get_height(self.win) ~= height then
      api.nvim_win_set_height(self.win, height)
    end
  end)

  self:on("BufWinEnter", function(event)
    if event.buf == self.buf then
      return
    end
    local win = api.nvim_get_current_win()
    if win ~= self.win then
      return
    end
    -- Prevent accidentally opening another file in the ssr window.
    -- Adapted from neo-tree.nvim.
    vim.schedule(function()
      api.nvim_win_set_buf(self.win, self.buf)
      local name = api.nvim_buf_get_name(event.buf)
      api.nvim_win_call(self.origin_win, function()
        pcall(api.nvim_buf_delete, event.buf, {})
        if name ~= "" then
          vim.cmd.edit(name)
        end
      end)
      api.nvim_set_current_win(self.origin_win)
    end)
  end)

  self:on("WinClosed", function()
    api.nvim_clear_autocmds { group = u.augroup }
    api.nvim_buf_delete(self.buf, {})
  end)
end

function MainWin:on_key(key, func)
  vim.keymap.set("n", key, func, { buffer = self.buf, nowait = true })
end

---@private
function MainWin:setup_keymaps()
  self:on_key(config.opts.keymaps.close, function()
    api.nvim_win_close(self.win, false)
  end)

  self:on_key("gg", function()
    u.set_cursor(self.win, 2, 0)
  end)

  self:on_key("j", function()
    local cursor = u.get_cursor(self.win)
    for _, extmark in ipairs { self.extmarks.replace, self.extmarks.results } do
      local skip_pos = api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, extmark, {})[1]
      if cursor == skip_pos - 1 then
        return pcall(u.set_cursor, self.win, skip_pos + 1, 0)
      end
    end
    vim.fn.feedkeys("j", "n")
  end)

  self:on_key("k", function()
    local cursor = u.get_cursor(self.win)
    if cursor <= 2 then
      return u.set_cursor(self.win, 2, 0)
    end
    for _, extmark in ipairs { self.extmarks.replace, self.extmarks.results } do
      local skip_pos = api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, extmark, {})[1]
      if cursor == skip_pos + 1 then
        return pcall(u.set_cursor, self.win, skip_pos - 1, 0)
      end
    end
    vim.fn.feedkeys("k", "n")
  end)

  self:on_key("l", function()
    local cursor = u.get_cursor(self.win)
    if cursor < self.result_list:get_start() then
      return vim.fn.feedkeys("l", "n")
    end
    self.result_list:set_folded(false)
  end)

  self:on_key("h", function()
    local cursor = u.get_cursor(self.win)
    if cursor < self.result_list:get_start() then
      return vim.fn.feedkeys("h", "n")
    end
    self.result_list:set_folded(true)
  end)
end

function MainWin:get_input()
  local pattern_pos = api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, self.extmarks.search, {})[1]
  local template_pos = api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, self.extmarks.replace, {})[1]
  local results_pos = api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, self.extmarks.results, {})[1]
  local lines = api.nvim_buf_get_lines(self.buf, 0, results_pos, true)
  local pattern = vim.list_slice(lines, pattern_pos + 2, template_pos)
  local template = vim.list_slice(lines, template_pos + 2)
  self.last_pattern = pattern
  self.last_template = template
  return vim.trim(table.concat(pattern, "\n")), vim.trim(table.concat(template, "\n"))
end

return MainWin
