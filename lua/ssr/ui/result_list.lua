local api = vim.api
local config = require "ssr.config"
local u = require "ssr.utils"

-- List item per line
---@class Item
---@field fold_idx integer which fold this line belongs to, 1-based
---@field match_idx integer which match this line belongs to, 0-based, 0 for filename

-- A foldable region that may span multiple lines
---@class Fold
---@field folded boolean
---@field filename string
---@field path string
---@field preview_lines string[]
local Fold = {}

---@param folded boolean
---@param file ssr.File
---@param matches ssr.Match[]
---@return Fold
function Fold.new(folded, file, matches)
  local preview_lines = {}
  for _, match in ipairs(matches) do
    local line = file.lines[match.range.start_row + 1]
    line = line:gsub("^%s*", "")
    table.insert(preview_lines, "│ " .. line)
  end
  return setmetatable({
    folded = folded,
    filename = vim.fn.fnamemodify(file.path, ":t"),
    path = vim.fn.fnamemodify(file.path, ":~:.:h"),
    preview_lines = preview_lines,
  }, { __index = Fold })
end

function Fold:len()
  if self.folded then return 1 end
  return 1 + #self.preview_lines
end

---@private
function Fold:get_lines()
  if self.folded then return { string.format(" %s %s %d", self.filename, self.path, #self.preview_lines) } end
  local lines = { string.format(" %s %s %d", self.filename, self.path, #self.preview_lines) }
  vim.list_extend(lines, self.preview_lines)
  return lines
end

function Fold:highlight(buf, row)
  local col = 4 -- "" is 3 bytes, plus 1 space
  api.nvim_buf_add_highlight(buf, u.namespace, "Directory", row, col, col + #self.filename)
  col = col + #self.filename + 1
  api.nvim_buf_add_highlight(buf, u.namespace, "Comment", row, col, col + #self.path)
  col = col + #self.path + 1
  api.nvim_buf_add_highlight(buf, u.namespace, "Number", row, col, col + #(tostring(self.preview_lines)))
end

---@class ResultList
---@field buf integer
---@field win integer
---@field extmark integer
---@field folds Fold[]
---@field items Item[]
local ResultList = {}

function ResultList.new(buf, win, extmark)
  local self = setmetatable({
    buf = buf,
    win = win,
    extmark = extmark,
    folds = {},
    items = {},
  }, { __index = ResultList })

  vim.keymap.set(
    "n",
    config.opts.keymaps.next_match,
    function() self:next_match() end,
    { buffer = self.buf, nowait = true }
  )
  vim.keymap.set(
    "n",
    config.opts.keymaps.prev_match,
    function() self:prev_match() end,
    { buffer = self.buf, nowait = true }
  )

  return self
end

---@private
function ResultList:get_start() return api.nvim_buf_get_extmark_by_id(self.buf, u.namespace, self.extmark, {})[1] + 1 end

---@params matches ssr.Matches
function ResultList:set(matches)
  self.folds = {}
  self.items = {}
  local start = self:get_start()
  api.nvim_buf_clear_namespace(self.buf, u.namespace, start, -1)

  local lines = {}
  for fold_idx, row in ipairs(matches) do
    local fold = Fold.new(fold_idx ~= 1, row.file, row.matches)
    table.insert(self.folds, fold)
    for match_idx, line in ipairs(fold:get_lines()) do
      table.insert(lines, line)
      table.insert(self.items, { fold_idx = fold_idx, match_idx = match_idx - 1 })
    end
  end
  api.nvim_buf_set_lines(self.buf, start, -1, true, lines)

  for _, fold in ipairs(self.folds) do
    fold:highlight(self.buf, start)
    start = start + fold:len()
  end
end

---@param folded boolean
---@param cursor integer?
function ResultList:set_folded(folded, cursor)
  local result_start = self:get_start()
  cursor = cursor or u.get_cursor(self.win) - result_start
  local item = self.items[cursor + 1] -- +1 beacause `cursor` is 0-based
  local fold = self.folds[item.fold_idx]
  if fold.folded == folded then return end

  local start = cursor - item.match_idx -- like C macro `container_of`
  local end_ = start + fold:len()
  fold.folded = folded
  local lines = fold:get_lines()
  local items = {}
  for i = 0, #lines - 1 do
    table.insert(items, { fold_idx = item.fold_idx, match_idx = i })
  end
  u.list_replace(self.items, start, end_, items)
  start = result_start + start
  end_ = result_start + end_
  api.nvim_buf_set_lines(self.buf, start, end_, true, lines)
  fold:highlight(self.buf, start)
  if folded then u.set_cursor(self.win, start, 0) end
end

function ResultList:next_match()
  local cursor = u.get_cursor(self.win)
  local result_start = self:get_start()
  cursor = cursor > result_start and cursor - result_start or 0
  local item = self.items[cursor + 1] -- +1: lua index
  if not item then return end
  if item.match_idx == 0 then self:set_folded(false, cursor) end
  cursor = cursor + 1
  item = self.items[cursor + 1]
  if not item then return end
  if item.match_idx == 0 then
    self:set_folded(false, cursor)
    cursor = cursor + 1
  end
  return u.set_cursor(self.win, cursor + result_start, 0)
end

function ResultList:prev_match()
  local cursor = u.get_cursor(self.win)
  local result_start = self:get_start()
  if cursor <= result_start then
    if #self.items == 0 then return end
    self:set_folded(false, #self.items - 1)
    return u.set_cursor(self.win, result_start + #self.items - 1, 0)
  end

  cursor = cursor - result_start
  local item = self.items[cursor + 1]
  if not item then return end
  if item.match_idx <= 1 then
    cursor = cursor - item.match_idx - 1
    item = self.items[cursor + 1]
    if not item then return end
    local fold = self.folds[item.fold_idx]
    if fold.folded then
      self:set_folded(false, cursor)
      cursor = cursor + #fold.preview_lines
    end
    return u.set_cursor(self.win, result_start + cursor, 0)
  end

  cursor = cursor - 1
  return u.set_cursor(self.win, cursor + result_start, 0)
end

return ResultList
