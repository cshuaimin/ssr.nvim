# ssr.nvim

[Structural search and replace](https://www.jetbrains.com/help/idea/structural-search-and-replace.html) for Neovim.

https://user-images.githubusercontent.com/24775746/199903092-a499dee1-af0a-444f-8ac1-24102454196f.mov

## Installation

with packer.nvim:

```lua
use {
  "cshuaimin/ssr.nvim",
  module = "ssr",
  -- Calling setup is optional.
  config = function()
    require("ssr").setup {
      border = "rounded",
      min_width = 50,
      min_height = 5,
      max_width = 120,
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
  end
}
```

then add a mapping to open SSR:

```lua
vim.keymap.set({ "n", "x" }, "<leader>sr", function() require("ssr").open() end)
```

## Usage

First put your cursor on the structure you want to search and replace (if you
are not sure, select a region instead), then open SSR by pressing `<leader>sr`.

In the SSR float window you can see the placeholder search code, you can
replace part of it with wildcards. A wildcard is an identifier starts with `$`,
like `$name`. A `$name` wildcard in the search pattern will match any AST node
and `$name` will reference it in the replacement.

Press `<leader><cr>` to replace all matches in current buffer, or `<cr>` to
choose which match to replace.

## The context

When opening SSR, the cursor position is important, you need to put the cursor
on the structure you want to search. If the placeholder code is not correct,
exit SSR with `q` and select the region instead.

ssr.nvim parses your search pattern to syntax trees to perform structural
searching. However directly parsing code without context is not accurate, for
example TypeScript function argument `foo: number` will be parsed as a label
without context, so ssr.nvim parses pattern in it's original context.

## Limitations

ssr.nvim performs searching and replacing at AST level and doesn't understand
code as much as LSP servers do. Use LSP server's ssr implementation if possible.
