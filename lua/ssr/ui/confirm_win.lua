local api = vim.api

---@class ConfirmWin
local ConfirmWin = {}

function ConfirmWin.new() end

function ConfirmWin:open()
  local buf = api.nvim_win_get_buf(self.origin_win)
  local matches = self.matches[buf]
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
      api.nvim_buf_set_extmark(
        confirm_buf,
        u.namespace,
        idx,
        4,
        { hl_group = "Underlined", end_row = idx, end_col = 5 }
      )
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
      border = config.options.border,
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
      -- TODO: `vim.api.nvim__redraw({ cursor = true, win = win })`
      api.nvim_buf_clear_namespace(confirm_buf, u.cur_search_ns, 0, -1)
      api.nvim_buf_set_extmark(
        confirm_buf,
        u.cur_search_ns,
        cursor - 1,
        0,
        { virt_text = { { "•", "Cursor" } }, virt_text_pos = "overlay" }
      )
      api.nvim_buf_set_extmark(confirm_buf, u.cur_search_ns, cursor - 1, 0, { line_hl_group = "CursorLine" })
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
        vim.fn.win_execute(self.origin_win, string.format('execute "normal! \\%s"', key))
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
  api.nvim_buf_clear_namespace(buf, u.cur_search_ns, 0, -1)
  self:set_status(string.format("%d/%d replaced", replaced, #matches))
end

return ConfirmWin
