local M = {}

---@class Config
M.opts = {
  border = "rounded",
  min_width = 50,
  max_width = 120,
  min_height = 6,
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

function M.set(config)
  M.opts = vim.tbl_deep_extend("force", M.opts, config)
end

return M
