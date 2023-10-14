local ts = vim.treesitter
local uv = vim.uv or vim.loop
local Searcher = require "ssr.search"
local pin_matches = require("ssr.replace").pin_matches
local replace = require("ssr.replace").replace
local u = require "ssr.utils"

---@type string[]
local tests = {}

---@param s string
local function t(s) table.insert(tests, s) end

t [[ operators
a = b + c ==>> x

==== t.py
a = b + c
a = b - c
a = b or c
====
x
a = b - c
a = b or c
]]

t [[ operators 2
a = b + c ==>> x

==== t.lua
a = b + c
a = b - c
a = b or c
====
x
a = b - c
a = b or c
]]

-- t [[ complex string
-- """
-- line 1
-- \r\n\a\\
-- 'a'"'"'b'
-- """ ==>> x
-- ==== t.py
-- """
-- line 1
-- \r\n\a\\
-- 'a'"'"'b'
-- """
-- ====
-- x
-- ]]

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
f(1, 2, 3)
f(1, 3)
====
f(1, 2, 3)
x
]]

t [[ recursive 1
f($a) ==>> $a.f()
==== recursive.lua
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
        if len(b) != 0:
            do_b(b)
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

t [[ reused capture: compound assignments
$a = $a + $b; ==>> $a += $b;
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

t [[ reused capture: indent
if $foo:
    if $foo:
        $body
==>>
if $foo:
    $body
==== t.py
def f():
    if await foo.bar(baz):
        if await foo.bar(baz):
            pass
====
def f():
    if await foo.bar(baz):
        pass
]]

-- two `foo`s have different type: `property_identifier` and `identifier`
t [[ reused capture: match different node types 1
{ $a: $a } ==>> { $a }
==== t.js
{ foo: foo }
{ foo: bar }
====
{ foo }
{ foo: bar }
]]

t [[ reused capture: match different node types 2
local $a = vim.$a ==>> x
==== t.lua
local api = vim.api
local a = vim.api
====
x
local a = vim.api
]]

t [[ multiple files
local $a = vim.$a ==>> _G.g_$a = vim.$a

==== t.lua
local api = vim.api
local fn = vim.fn
====
_G.g_api = vim.api
_G.g_fn = vim.fn

==== README.md
# Example
```lua
local F = vim.F
local uv = vim.uv
```
====
# Example
```lua
_G.g_F = vim.F
_G.g_uv = vim.uv
```
]]

t [=[ regex generic over languages
t [[1 + 2]] ==>> x

==== t.lua
t [[1 + 2]]
t([[1 + 2]])
t [[1+2]]
====
x
x
t [[1+2]]

==== t.py
t[[1+2]]
t [ [1 + 2] ]
====
x
x
]=]

describe("", function()
  -- Plenary runs nvim with `--noplugin` argument.
  -- Load nvim-treesitter to make `ts.language.get_lang()` work.
  require "nvim-treesitter"

  for _, s in ipairs(tests) do
    local desc, pattern, template, rest = s:match "^ (.-)\n(.-)%s?==>>%s?(.-)\n%s*==(.-)$"
    it(desc, function()
      local dir = vim.fn.tempname()
      assert(uv.fs_mkdir(dir, 448))

      local expected_files = {}
      local lang
      for fname, before, after in (rest .. "=="):gmatch "== (.-)\n(.-)====\n(.-)%s*==" do
        after = after .. "\n" -- Vim always adds a \n to files.
        fname = vim.fs.joinpath(dir, fname)
        local fd = assert(uv.fs_open(fname, "w", 438))
        assert(uv.fs_write(fd, before) > 0)
        assert(uv.fs_close(fd))
        expected_files[fname] = after
        lang = lang or assert(ts.language.get_lang(vim.filetype.match { filename = fname }))
      end

      local matches = nil
      local searcher = Searcher.new(pattern)
      searcher:search(dir, function(m) matches = m end)
      vim.wait(1000, function() return matches end)

      local pinned_matches = pin_matches(matches)
      for _, match in ipairs(pinned_matches) do
        replace(match, template)
      end

      vim.cmd "silent noautocmd wa"
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
