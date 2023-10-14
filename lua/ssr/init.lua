local M = {}

--- Set config options. Optional.
---@param config Config?
function M.setup(config)
  if config then
    require("ssr.config").set(config)
  end
end

function M.open()
  require("ssr.ui").new()
end

return M
