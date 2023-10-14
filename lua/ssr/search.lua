-- local ts = vim.treesitter
-- vim.func = require "vim.func"
vim.F = require "vim.F"
local uv = vim.uv or vim.loop
local ts = require "vim.treesitter"
local Range = require "ssr.range"
local u = require "ssr.utils"

-- Compare if two captured trees can match.
-- The check is loose because we want to match different types of node.
-- e.g. converting `{ foo: foo }` to shorthand `{ foo }`.
ts.query.add_predicate("ssr-tree-match?", function(match, _pattern, buf, pred)
  ---@param node1 TSNode
  ---@param node2 TSNode
  ---@return boolean
  local function tree_match(node1, node2)
    if node1:named() ~= node2:named() then return false end
    if node1:child_count() == 0 or node2:child_count() == 0 then
      return ts.get_node_text(node1, buf) == ts.get_node_text(node2, buf)
    end
    if node1:child_count() ~= node2:child_count() then return false end
    for i = 0, node1:child_count() - 1 do
      if
        not tree_match(node1:child(i) --[[@as TSNode]], node2:child(i) --[[@as TSNode]])
      then
        return false
      end
    end
    return true
  end
  return tree_match(match[pred[2]], match[pred[3]])
end, { force = true })

-- In grammars like Lua some important nodes do not have a field name.
local crucial_nodes_without_field_name = {
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["#"] = true,
  ["~"] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
}

-- Build a TS sexpr represting the node.
-- This function is more strict than `TSNode:sexpr()` by also requiring leaf nodes to match text.
---@param node TSNode
---@param source string
---@return string sexpr
---@return table<string, integer> captures
local function build_sexpr(node, source)
  ---@type table<string, integer>
  local captures = {}
  local next_idx = 1

  ---@param node TSNode
  ---@return string?
  local function build(node)
    if not node:named() then return string.format('"%s"', u.ts_str_escape(node:type())) end

    -- Handle captures early to capture the largest node.
    local text = ts.get_node_text(node, source)
    local var = text:match("^" .. u.capture_prefix .. "([_%a%d]+)$")
    if var then
      if not captures[var] then
        captures[var] = next_idx
        next_idx = next_idx + 1
        return "(_) @" .. var
      else
        -- Same capture should match the same subtree.
        local sexpr = string.format("(_) @_%d (#ssr-tree-match? @_%d @%s)", next_idx, next_idx, var)
        next_idx = next_idx + 1
        return sexpr
      end
    end

    -- Leaf nodes (identifier, literal and symbol) should match text.
    if node:named_child_count() == 0 then
      local sexpr = string.format('(%s) @_%d (#eq? @_%d "%s")', node:type(), next_idx, next_idx, u.ts_str_escape(text))
      next_idx = next_idx + 1
      return sexpr
    end

    -- Normal nodes
    local sexpr = ""
    local add_anchor = false
    for child, field in node:iter_children() do
      if field then
        if add_anchor then
          sexpr = sexpr .. " ."
          add_anchor = false
        end
        sexpr = string.format("%s %s: %s", sexpr, field, build(child))
      elseif child:named() or crucial_nodes_without_field_name[child:type()] then
        -- Pin child position with anchor `.`
        sexpr = string.format(" %s . %s", sexpr, build(child))
        add_anchor = true
      end
    end
    if add_anchor then sexpr = sexpr .. " ." end
    return string.format("(%s %s)", node:type(), sexpr)
  end

  local sexpr = string.format("(%s) @all", build(node))
  return sexpr, captures
end

---@class ssr.Searcher
---@field pattern string
---@field rough_regex string
---@field queries table<string, vim.treesitter.Query | vim.NIL>
---@field captures table<string, integer>
local Searcher = {}

---@param lang string
---@param pattern string
---@return vim.treesitter.Query | vim.NIL, table<string, integer>?, TSNode?
local function parse_pattern(lang, pattern)
  local node = ts.get_string_parser(pattern, lang):parse()[1]:root()
  local lines = vim.split(pattern, "\n", { plain = true })
  node = node:named_descendant_for_range(0, 0, #lines - 1, #lines[#lines]) --[[@as TSNode]]
  if node:has_error() then return vim.NIL end
  local sexpr, captures = build_sexpr(node, pattern)
  local query = ts.query.parse(lang, sexpr)
  return query, captures, node
end

---@param lang string
---@param pattern string
---@return ssr.Searcher?
function Searcher.new(lang, pattern)
  -- $ can cause syntax errors in most languages
  pattern = pattern:gsub("%$([_%a%d]+)", u.capture_prefix .. "%1")
  -- local query = parse_pattern(lang, pattern)
  -- if query == vim.NIL then return end
  return setmetatable({
    pattern = pattern,
    rough_regex = u.build_rough_regex(pattern),
    queries = {},
    captures = nil,
  }, { __index = Searcher })
end

-- A single match, including its captures.
---@class ssr.Match
---@field range ssr.Range
---@field captures table<string, ssr.Range>

---@param file ssr.File
---@return ssr.Match[]
function Searcher:search_file(file)
  ---@type ssr.Match[]
  local matches = {}
  file.tree:for_each_tree(function(tree, lang_tree) -- must called :parse(true)
    local lang = lang_tree:lang()
    local query = self.queries[lang]
    if query == vim.NIL then -- cached failure
      return
    elseif not query then
      query, c = parse_pattern(lang, self.pattern)
      if query == vim.NIL then return end
      self.queries[lang] = query
      self.captures = c
    end
    for _, nodes in query:iter_matches(tree:root(), file.text, 0, -1) do
      local range = Range.from_node(nodes[#nodes])
      local captures = {}
      for var, idx in pairs(self.captures) do
        captures[var] = Range.from_node(nodes[idx])
      end
      table.insert(matches, { range = range, captures = captures })
    end
  end)

  -- Sort matches from
  --  buffer top to bottom, to make goto next/prev match intuitive
  --  inner to outer for recursive matches, to make replacing correct
  ---@param match1 ssr.Match
  ---@param match2 ssr.Match
  ---@return boolean
  table.sort(matches, function(match1, match2)
    if match1.range:before(match2.range) then return true end
    return match1.range:inside(match2.range)
  end)
  return matches
end

-- Cached file contents and its TS tree.
---@type table<string, ssr.File>
local cache = {}

---@class ssr.File
---@field text string
---@field tree vim.treesitter.LanguageTree
---@field mtime { nsec: integer, sec: integer }

---@alias ssr.Matches { file: ssr.File, matches: ssr.Match[] }[]

-- Recursively search the directory.
---@param dir string
---@param callback fun(ssr.Matches)
function Searcher:search(dir, callback)
  -- Runs in a new Lua state.
  local function work_func(self, path, file)
    local uv = vim.uv or vim.loop
    local ts = vim.treesitter

    vim.g = {}
    local fd = uv.fs_open(path, "r", 438)
    if not fd then return end
    local stat = uv.fs_fstat(fd) ---@cast stat -?
    if not file or file.mtime.sec ~= stat.mtime.sec or file.mtime.nsec ~= stat.mtime.nsec then
      local text = uv.fs_read(fd, stat.size, 0) ---@cast text -?
      local lang = "lua"
      local has_parser, tree = pcall(ts.get_string_parser, text, lang)
      if not has_parser then
        print("no parser", tree, lang, vim._ts_has_language(lang))
        uv.fs_close(fd)
        return
      end
      tree:parse(true)
      file = { text = text, tree = tree, mtime = stat.mtime }
    end
    uv.fs_close(fd)

    local s = require "ssr.search"
    setmetatable(self, { __index = s })
    return file, self:search_file(file)
  end

  local works = 0
  local done = 0
  local rg_done = false
  local matches = {}

  local function start_work(path)
    works = works + 1
    local work = uv.new_work(work_func, function(file, m)
      if not file then return end
      cache[path] = file
      table.insert(matches, { file = file, matches = m })
      done = done + 1
      if rg_done and done == works then vim.schedule_wrap(callback)(matches) end
    end)

    work:queue(self, path, cache[path])
  end

  vim.system(
    { "rg", "--line-buffered", "--files-with-matches", "--multiline", "--multiline-dotall", self.rough_regex, dir },
    {
      text = true,
      stdout = function(err, files)
        if err then error(files) end
        if not files then
          rg_done = true
          return
        end
        for _, path in ipairs(vim.split(files, "\n", { plain = true, trimempty = true })) do
          start_work(path)
        end
      end,
    },
    function(obj)
      if obj.code == 1 then -- no match was found
        rg_done = true
      elseif obj.code ~= 0 then
        error(obj.stderr)
      end
    end
  )
end

return Searcher
