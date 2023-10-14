local api = vim.api
local ts = vim.treesitter
local uv = vim.uv or vim.loop
local config = require "ssr.config"
local Searcher = require "ssr.search"
local replace = require("ssr.replace").replace
local pin_matches = require("ssr.replace").pin_matches
local MainWin = require "ssr.ui.main_win"
local u = require "ssr.utils"

---@class Ui
---@field lang string
---@field matches ssr.Matches
---@field last_pattern string
---@field main_win MainWin
local Ui = {}

---@return Ui?
function Ui.new()
  local self = setmetatable({ matches = {} }, { __index = Ui })

  -- Pre-checks
  local origin_win = api.nvim_get_current_win()
  local origin_buf = api.nvim_win_get_buf(origin_win)
  -- if api.nvim_buf_get_name(origin_buf) == "" and vim.bo[origin_buf].buftype == "" then
  -- end

  local lang = ts.language.get_lang(vim.bo[origin_buf].filetype)
  if not lang then
    return u.notify(string.format("Treesitter language not found for filetype '%s'", vim.bo[origin_buf].filetype))
  end
  self.lang = lang
  local node = u.node_for_range(origin_buf, self.lang, u.get_selection(origin_win))
  if not node then
    return u.notify("Treesitter parser not found, please try to install it with :TSInstall " .. self.lang)
  end
  if node:has_error() then return u.notify "You have syntax errors in the selected node" end
  -- Extend the selected node if it can't be parsed without context.
  repeat
    local text = ts.get_node_text(node, origin_buf)
    local root = ts.get_string_parser(text, self.lang):parse()[1]:root()
    local lines = vim.split(text, "\n", { plain = true })
    local n = root:named_descendant_for_range(0, 0, #lines - 1, #lines[#lines])
    if not n:has_error() then break end
    node = node:parent()
  until not node
  if not node then return u.notify "Selected node can't be properly parsed." end

  local placeholder = vim.split(ts.get_node_text(node, origin_buf), "\n", { plain = true })
  u.remove_indent(placeholder, u.get_indent(origin_buf, node:start()))

  self.main_win = MainWin.new(lang, placeholder, { "" }, origin_win)

  self.main_win:on({ "InsertLeave", "TextChanged" }, function() self:search() end)

  self.main_win:on_key(config.opts.keymaps.replace_all, function() self:replace_all() end)

  self:search()
  return self
end

function Ui:search()
  local pattern = self.main_win:get_input()
  if pattern == self.last_pattern then return end
  self.last_pattern = pattern

  local start = vim.loop.hrtime()
  self.matches = {}
  local found = 0
  local matched_files = 0

  local searcher = Searcher.new(self.lang, pattern)
  if not searcher then return self:set_status "ERROR" end
  searcher:search(vim.fn.getcwd(-1), function(matches)
    local elapsed = (vim.loop.hrtime() - start) / 1E6
    self.matches = matches
    vim.print(#matches)
    self.main_win.result_list:set(self.matches)
    self:set_status(string.format("%d found in %d files (%dms)", found, matched_files, elapsed))
  end)
end

function Ui:replace_all()
  if #self.matches == 0 then return self:set_status "pattern not found" end
  local _, template = self.main_win:get_input()
  local start = vim.loop.hrtime()
  local pinned = pin_matches(self.matches)
  for _, match in ipairs(pinned) do
    replace(match, template)
  end
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  self:set_status(string.format("%d replaced in %d files (%dms)", #self.matches, 0, elapsed))
end

---@param status string
---@return nil
function Ui:set_status(status)
  api.nvim_buf_set_extmark(self.main_win.buf, u.namespace, 0, 0, {
    id = self.main_win.extmarks.status,
    virt_text = {
      { "[SSR] ", "Comment" },
      { status },
      { " (Press ? for help)", "Comment" },
    },
    virt_text_pos = "overlay",
  })
end

return Ui
