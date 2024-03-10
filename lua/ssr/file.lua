local api = vim.api
local ts = vim.treesitter
local uv = vim.uv or vim.loop

-- File contents and it's parsed tree
-- Unloaded buffers are read with libuv because loading a vim buffer can be up to 100x slower.
---@class File
---@field path string
---@field source string | buffer
---@field tree vim.treesitter.LanguageTree
-- Only if `source` is file content
---@field lines? string[]
---@field mtime? { nsec: integer, sec: integer }
local File = {}

---@type table<string, File>
local cache = {}

---@param path string
---@return File?
function File.new(path)
  -- First check if the file is already opened as a buffer.
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 then
    cache[path] = nil
    if vim.bo[buf].filetype == "" then
      local ft = vim.filetype.match { buf = buf }
      api.nvim_buf_call(buf, function()
        vim.cmd("noautocmd setlocal filetype=" .. ft)
      end)
    end
    return setmetatable({
      path = path,
      source = buf,
      tree = ts.get_parser(buf),
    }, { __index = File })
  end

  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return
  end
  local stat = uv.fs_fstat(fd) ---@cast stat -?
  local self = cache[path]
  if self then
    if stat.mtime.sec == self.mtime.sec and stat.mtime.nsec == self.mtime.nsec then
      uv.fs_close(fd)
      return self
    else
      cache[path] = nil
    end
  end
  local source = uv.fs_read(fd, stat.size, 0) --[[@as string]]
  uv.fs_close(fd)
  local lines = vim.split(source, "\n", { plain = true })
  local ft = vim.filetype.match { filename = path, contents = lines } -- not work for .ts
  if not ft then
    return
  end
  local lang = ts.language.get_lang(ft)
  if not lang then
    return
  end
  local has_parser, tree = pcall(ts.get_string_parser, source, lang)
  if not has_parser then
    return
  end
  tree:parse(true)
  self = setmetatable({
    path = path,
    source = source,
    tree = tree,
    filetype = ft,
    lines = lines,
    mtime = stat.mtime,
  }, { __index = File })
  cache[path] = self
  return self
end

---@param line number
---@return string
function File:get_line(line)
  if type(self.source) == "number" then
    return api.nvim_buf_get_lines(self.source, line, line + 1, true)[1]
  end
  return self.lines[line + 1]
end

function File:load_buf()
  if type(self.source) == "number" then
    return
  end
  self.source = vim.fn.bufadd(self.path)
  vim.fn.bufload(self.buf)
  api.nvim_buf_call(self.source, function()
    vim.cmd("noautocmd setlocal filetype=" .. self.filetype)
  end)
  self.lines = nil
  self.mtime = nil
  cache[self.path] = nil
end

---@param regex string
---@param on_file fun(file: File)
---@param on_end fun()
---@return nil
function File.grep(regex, on_file, on_end)
  vim.system(
    { "rg", "--line-buffered", "--files-with-matches", "--multiline", regex },
    {
      text = true,
      stdout = vim.schedule_wrap(function(err, files)
        if err then
          error(files)
        end
        if not files then
          on_end()
          return
        end
        for _, path in ipairs(vim.split(files, "\n", { plain = true, trimempty = true })) do
          local file = File.new(path)
          if file then
            on_file(file)
          end
        end
      end),
    },
    vim.schedule_wrap(function(obj)
      if obj.code == 1 then -- no match was found
        on_end()
      elseif obj.code ~= 0 then
        error(obj.stderr)
      end
    end)
  )
end

function File.clear_cache()
  cache = {}
end

return File
