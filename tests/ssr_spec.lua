local uv = vim.uv or vim.loop
local ParseContext = require "ssr.parse_context"
local Searcher = require "ssr.search"
local Replacer = require "ssr.replace"
local File = require "ssr.file"

---@type string[]
local tests = {}

---@param s string
local function t(s)
  table.insert(tests, s)
end

t [[ operators
a + b ==>> (+ a b)
==== t.py
a + b
a - b
====
(+ a b)
a - b
]]

t [[ complex string
"""
line 1
\r\n\a\?\\
'a'"'"'b'
""" ==>> x
==== t.py
"""
line 1
\r\n\a\?\\
'a'"'"'b'
"""
====
x
]]

t [[ keywords
let a = 1 ==>> x
==== t.js
let a = 1
const a = 1
====
x
const a = 1
]]

t [[ func args
f(1, 3) ==>> x
==== t.lua
<f(1, 2, 3)>
f(1, 3)
====
f(1, 2, 3)
x
]]

t [[ recursive 1
f($a) ==>> $a.f()
==== t.lua
f(f(f(0)))
====
0.f().f().f()
]]

t [[ recursive 2
f($a, $b) ==>> $a.f($b)
==== t.rs
f(f(f(0, 1), 2), 3)
====
0.f(1).f(2).f(3)
]]

t [[ recursive 3
f($a, $b) ==>> $a.f($b)
==== t.rs
f(3, f(2, f(1, 0)))
====
3.f(2.f(1.f(0)))
]]

t [[ indent 1
if $a:
    $b
==>>
if $a:
    if True:
        $b
==== t.py
def f():
    if foo:
        if bar:
            pass
====
def f():
    if foo:
        if True:
            if bar:
                if True:
                    pass
]]

t [[ indent 2
if len($a) != 0:
    $b
==>>
if $a:
    $b
==== t.py
def f():
    if len(a) != 0:
        do_a(a)
        <if len(b) != 0:
            do_b(b)>
====
def f():
    if a:
        do_a(a)
        if b:
            do_b(b)
]]

t [[ question mark
$a? ==>> try!($a)
==== t.rs
let foo = bar().await?;
====
let foo = try!(bar().await);
]]

t [[ rust-analyzer ssr example
foo($a, $b) ==>> ($a).foo($b)
==== t.rs
String::from(foo(y + 5, z))
====
String::from((y + 5).foo(z))
]]

t [[ match Go if err
if err != nil { panic(err) } ==>> x
==== t.go
fn main() {
    if err != nil {
        panic(err)
    }
}
====
fn main() {
    x
}
]]

t [[ reused wildcard: compound assignments
$a = $a + $b ==>> $a += $b
==== t.rs
idx = idx + 1;
bar = foo + idx;
*foo.bar() = * foo . bar () + 1;
(foo + bar) = (foo + bar) + 1;
(foo + bar) = (foo - bar) + 1;
====
idx += 1;
bar = foo + idx;
*foo.bar() += 1;
(foo + bar) += 1;
(foo + bar) = (foo - bar) + 1;
]]

t [[ reused wildcard: indent
if $foo:
    if $foo:
        $body
==>>
if $foo:
    $body
==== t.py
def f():
    <if await foo.bar(baz):
        if await foo.bar(baz):
            pass>
====
def f():
    if await foo.bar(baz):
        pass
]]

-- two `foo`s have different type: `property_identifier` and `identifier`
t [[ reused wildcard: match different node types 1
{ $a: $a } ==>> { $a }
==== t.js
{ foo: foo }
{ foo: bar }
====
{ foo }
{ foo: bar }
]]

t [[ reused wildcard: match different node types 2
local $a = vim.$a ==>> x
==== t.lua
local api = vim.api
local a = vim.api
====
x
local a = vim.api
]]

t [[ multiple files
local $a = vim.$a ==>> local __$a__ = vim.$a

**** t.lua
local api = vim.api
local fn = vim.fn
****
local __api__ = vim.api
local __fn__ = vim.fn

**** README.md
# Example
```lua
local F = vim.F
local uv = vim.uv
```
****
# Example
```lua
local __F__ = vim.F
local __uv__ = vim.uv
```
]]

describe("", function()
  -- Plenary runs nvim with `--noplugin` argument.
  -- Make sure nvim-treesitter is loaded, which populates vim.treesitter's ft_to_lang table.
  require "nvim-treesitter"

  for _, s in ipairs(tests) do
    local desc, pattern, template, rest = s:match "^ (.-)\n(.-)%s?==>>%s?(.-)\n%s?%*%*(.-)$"
    it(desc, function()
      local expected_files = {}
      for fname, before, after in (rest .. "**"):gmatch "%*%* (.-)\n(.-)\n%*%*%*%*\n(.-)\n%*%*" do
        fname = vim.fn.tempname() .. "_" .. fname
        local fd = assert(uv.fs_open(fname, "w", 438))
        uv.fs_write(fd, before)
        uv.fs_close(fd)
        expected_files[fname] = after
      end

      local empty_context = ParseContext.empty "TODO"
      local searcher = assert(Searcher.new("TODO", pattern, empty_context))
      local results = {}
      local done = false
      File.grep(searcher.rough_regex, function(file)
        local matches = searcher:search(file)
        assert(#matches > 0)
        table.insert(results, { file = file, matches = matches })
      end, function()
        done = true
      end)
      vim.wait(10 * 1000, function()
        return done
      end)

      local replacer = Replacer
      for _, result in ipairs(results) do
        result.file:load_buf()
        for _, match in ipairs(result.matches) do
          replacer:replace(result.file.source, template, match)
        end
      end
      vim.cmd "wa"
      for fname, expected in pairs(expected_files) do
        local fd = assert(uv.fs_open(fname, "r", 438))
        local stat = assert(uv.fs_fstat(fd))
        local actual = uv.fs_read(fd, stat.size, 0)
        uv.fs_close(fd)
        assert.are.same(expected, actual)
      end
    end)
  end
end)
