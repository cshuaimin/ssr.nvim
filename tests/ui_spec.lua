local api = vim.api

describe("match navigation", function()
  local origin_buf, origin_win, ui_win, ui

  before_each(function()
    origin_win = api.nvim_get_current_win()
    origin_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(origin_win, origin_buf)
    vim.bo[origin_buf].filetype = "lua"
    api.nvim_buf_set_lines(origin_buf, 0, -1, true, { "f(1)", "f(2)" })
    api.nvim_win_set_cursor(origin_win, { 1, 0 })
    ui = assert(require("ssr").open())
    ui_win = api.nvim_get_current_win()
  end)

  after_each(function()
    api.nvim_win_close(ui_win, false)
    api.nvim_buf_delete(origin_buf, {})
  end)

  local function press(key)
    for _, mapping in ipairs(api.nvim_buf_get_keymap(ui.ui_buf, "n")) do
      if mapping.lhs == key then
        mapping.callback()
        return
      end
    end
    error("Missing mapping: " .. key)
  end

  it("keeps the cursor still when the pattern has no matches", function()
    api.nvim_buf_set_lines(ui.ui_buf, 2, 3, true, { "g($a)" })
    api.nvim_exec_autocmds("TextChanged", { buffer = ui.ui_buf })
    assert.are.equal(0, #ui.buf_matches[origin_buf])
    local cursor = api.nvim_win_get_cursor(origin_win)
    local status = api.nvim_buf_get_extmark_by_id(ui.ui_buf, ui.ns, ui.extmarks.status, { details = true })
    press "n"
    press "N"
    assert.are.same(cursor, api.nvim_win_get_cursor(origin_win))
    assert.are.same(status, api.nvim_buf_get_extmark_by_id(ui.ui_buf, ui.ns, ui.extmarks.status, { details = true }))

    api.nvim_buf_set_lines(ui.ui_buf, 2, 3, true, { "f($a)" })
    api.nvim_exec_autocmds("TextChanged", { buffer = ui.ui_buf })
    press "n"
    assert.are.same({ 2, 0 }, api.nvim_win_get_cursor(origin_win))
    press "N"
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(origin_win))
  end)
end)
