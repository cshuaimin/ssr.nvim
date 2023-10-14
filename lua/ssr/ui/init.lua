local api = vim.api
local ts = vim.treesitter
local config = require "ssr.config"
local ParseContext = require "ssr.parse_context"
local Searcher = require "ssr.search"
local Replacer = require "ssr.replace"
local File = require "ssr.file"
local MainWin = require "ssr.ui.main_win"
local u = require "ssr.utils"

---@class Ui
---@field lang string
---@field parse_context ParseContext
---@field results { file: File, matches: Match[] }[]
---@field last_pattern string
---@field main_win MainWin
local Ui = {}

---@return Ui?
function Ui.new()
  local self = setmetatable({ matches = {} }, { __index = Ui })

  -- Pre-checks
  local origin_win = api.nvim_get_current_win()
  local origin_buf = api.nvim_win_get_buf(origin_win)
  local lang = ts.language.get_lang(vim.bo[origin_buf].filetype)
  if not lang then
    return u.notify(string.format("Treesitter language not found for filetype '%s'", vim.bo[origin_buf].filetype))
  end
  self.lang = lang
  local origin_node = u.node_for_range(origin_buf, self.lang, u.get_selection(origin_win))
  if not origin_node then
    return u.notify("Treesitter parser not found, please try to install it with :TSInstall " .. self.lang)
  end
  if origin_node:has_error() then
    return u.notify "You have syntax errors in the selected node"
  end
  local parse_context = ParseContext.new(origin_buf, self.lang, origin_node)
  if not parse_context then
    return u.notify "Can't find a proper context to parse the pattern"
  end
  self.parse_context = parse_context

  local placeholder = vim.split(ts.get_node_text(origin_node, origin_buf), "\n", { plain = true })
  u.remove_indent(placeholder, u.get_indent(origin_buf, origin_node:start()))

  self.main_win = MainWin.new(lang, placeholder, { "" }, origin_win)

  self.main_win:on({ "InsertLeave", "TextChanged" }, function()
    self:search()
  end)

  self.main_win:on_key(config.opts.keymaps.replace_all, function()
    self:replace_all()
  end)

  self:search()
  return self
end

function Ui:search()
  local pattern = self.main_win:get_input()
  if pattern == self.last_pattern then
    return
  end
  self.last_pattern = pattern

  self.results = {}
  local found = 0
  local matched_files = 0
  local start = vim.loop.hrtime()
  local searcher = Searcher.new(self.lang, pattern, self.parse_context)
  if not searcher then
    return self:set_status "Error"
  end

  File.grep(searcher.rough_regex, function(file)
    local matches = searcher:search(file)
    if #matches == 0 then
      return
    end
    found = found + #matches
    matched_files = matched_files + 1
    table.insert(self.results, { file = file, matches = matches })
  end, function()
    local elapsed = (vim.loop.hrtime() - start) / 1E6
    self.main_win.result_list:set(self.results)
    self:set_status(string.format("%d found in %d files (%dms)", found, matched_files, elapsed))
  end)
end

function Ui:replace_all()
  if #self.results == 0 then
    return self:set_status "pattern not found"
  end
  local _, template = self.main_win:get_input()
  local start = vim.loop.hrtime()
  local replacer = Replacer
  for _, result in ipairs(self.results) do
    result.file:load_buf()
    for _, match in ipairs(result.matches) do
      replacer:replace(result.file.source, template, match)
    end
  end
  local elapsed = (vim.loop.hrtime() - start) / 1E6
  self:set_status(string.format("%d replaced in %d files (%dms)", #self.results, 0, elapsed))
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
