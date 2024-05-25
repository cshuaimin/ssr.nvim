local u = require "ssr.utils"
local ParseContext = require("ssr.parse").ParseContext
local ts = vim.treesitter
local search = require("ssr.search").search
local replace = require("ssr.search").replace

local tests = {}

local function t(s)
  table.insert(tests, s)
end

t [[ python operators
<a + b>
a - b
====
a + b ==>> (+ a b)
====
(+ a b)
a - b
]]

t [[ python complex string
<"""
line 1
\r\n\a\?\\
'a'"'"'b'
""">
====
"""
line 1
\r\n\a\?\\
'a'"'"'b'
"""
==>>
x
====
x
]]

t [[ javascript keywords
<let a = 1>
const a = 1
====
let a = 1 ==>> x
====
x
const a = 1
]]

t [[ lua func args
<f(1, 2, 3)>
f(1, 3)
====
f(1, 3) ==>> x
====
f(1, 2, 3)
x
]]

t [[ lua recursive 1
<f(f(f(0)))>
====
f($a) ==>> $a.f()
====
0.f().f().f()
]]

t [[ rust recursive 2
f(f(<f(0, 1)>, 2), 3)
====
f($a, $b) ==>> $a.f($b)
====
0.f(1).f(2).f(3)
]]

t [[ rust recursive 3
f(3, f(2, <f(1, 0)>))
====
f($a, $b) ==>> $a.f($b)
====
3.f(2.f(1.f(0)))
]]

t [[ python indent 1
def f():
    <if foo:
        if bar:
            pass>
====
if $a:
    $b
==>>
if $a:
    if True:
        $b
====
def f():
    if foo:
        if True:
            if bar:
                if True:
                    pass
]]

t [[ python indent 2
def f():
    if len(a) != 0:
        do_a(a)
        <if len(b) != 0:
            do_b(b)>
====
if len($a) != 0:
    $b
==>>
if $a:
    $b
====
def f():
    if a:
        do_a(a)
        if b:
            do_b(b)
]]

t [[ rust question mark
let foo = <bar().await?>;
====
$a? ==>> try!($a)
====
let foo = try!(bar().await);
]]

t [[ rust rust-analyzer ssr example
String::from(<foo(y + 5, z)>)
====
foo($a, $b) ==>> ($a).foo($b)
====
String::from((y + 5).foo(z))
]]

t [[ go parse Go := in function
func main() {
    <commit, _ := os.LookupEnv("GITHUB_SHA")>
}
====
$a, _ := os.LookupEnv($b)
==>>
$a := os.Getenv($b)
====
func main() {
    commit := os.Getenv("GITHUB_SHA")
}
]]

t [[ go match Go if err
fn main() {
    <if err != nil {
        panic(err)
    }>
}
====
if err != nil { panic(err) } ==>> x
====
fn main() {
    x
}
]]

t [[ rust reused wildcard: compound assignments
<idx = idx + 1>;
bar = foo + idx;
*foo.bar() = * foo . bar () + 1;
(foo + bar) = (foo + bar) + 1;
(foo + bar) = (foo - bar) + 1;
====
$a = $a + $b ==>> $a += $b
====
idx += 1;
bar = foo + idx;
*foo.bar() += 1;
(foo + bar) += 1;
(foo + bar) = (foo - bar) + 1;
]]

t [[ python reused wildcard: indent
def f():
    <if await foo.bar(baz):
        if await foo.bar(baz):
            pass>
====
if $foo:
    if $foo:
        $body
==>>
if $foo:
    $body
====
def f():
    if await foo.bar(baz):
        pass
]]

-- two `foo`s have different type: `property_identifier` and `identifier`
t [[ javascript reused wildcard: match different node types 1
<{ foo: foo }>
{ foo: bar }
====
{ $a: $a } ==>> { $a }
====
{ foo }
{ foo: bar }
]]

t [[ lua reused wildcard: match different node types 2
<local api = vim.api>
local a = vim.api
====
local $a = vim.$a ==>> x
====
x
local a = vim.api
]]

t [[ bash escape dollar sign in pattern
<$FOO=$$BAR>
====
$$FOO=$$$$BAR ==>> foo
====
foo
]]

t [[ bash escape dollar sign in template
<${FOO:-bar}>
====
$${FOO:-$b} ==>> $b$$b$$$b
====
bar$b$bar
]]

describe("", function()
  -- Plenary runs nvim with `--noplugin` argument.
  -- Make sure nvim-treesitter is loaded, which populates vim.treesitter's ft_to_lang table.
  require "nvim-treesitter"

  for _, s in ipairs(tests) do
    local ft, desc, content, pattern, template, expected =
      s:match "^ (%a-) (.-)\n(.-)%s?====%s?(.-)%s?==>>%s?(.-)%s?====%s?(.-)%s?$"
    content = vim.split(content, "\n")
    expected = vim.split(expected, "\n")
    local start_row, start_col, end_row, end_col
    for idx, line in ipairs(content) do
      local col = line:find "<"
      if col then
        start_row = idx - 1
        start_col = col - 1
      end
      line = line:gsub("<", "")
      col = line:find ">"
      if col then
        end_row = idx - 1
        end_col = col - 1
      end
      line = line:gsub(">", "")
      content[idx] = line
    end

    it(desc, function()
      local ns = vim.api.nvim_create_namespace ""
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = ft
      vim.api.nvim_buf_set_lines(buf, 0, -1, true, content)
      local lang = ts.language.get_lang(vim.bo[buf].filetype)
      assert(lang, "language not found")
      local origin_node = u.node_for_range(buf, lang, start_row, start_col, end_row, end_col)

      local parse_context = ParseContext.new(buf, origin_node)
      assert(parse_context)
      local node, source = parse_context:parse(pattern)
      local matches = search(buf, node, source, ns)

      for _, match in ipairs(matches) do
        replace(buf, match, template)
      end

      local actual = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
      vim.api.nvim_buf_delete(buf, {})
      assert.are.same(expected, actual)
    end)
  end
end)
