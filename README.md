This is a plugin for vim 8.1+ and neovim 0.3.6+ that you can use to toggle
(set or delete) an `lldb` breakpoint for the current line from within vim.

> _**Note:** This is a fork of https://github.com/epheien/termdbg, with changes
> that limit it to `lldb` only_.

-------------------------------------------------------------------------------

### Install

Requirements: vim 8.1+ (`+terminal`) or neovim 0.3.6+.

For manual installation:

```bash
mkdir -p ~/.vim/pack/lldbvim/start
cd ~/.vim/pack/lldbvim/start
git clone git@github.com:sideshowbarker/lldbvim.git
```

For [vim-plug](https://github.com/junegunn/vim-plug):

```
Plug 'sideshowbarker/lldbvim'
```

-------------------------------------------------------------------------------

### Usage

```
:Lldb
```

-------------------------------------------------------------------------------

### Commands

- `:LToggleBreakpoint` – toggle (set or delete) breakpoint at current line
- `:LDeleteAllBreakpoints` – delete all breakpoints

-------------------------------------------------------------------------------

### Options

```viml
" 'lldb_program' is set by default to either 'lldb' or (depending on filetype)
" 'rust-lldb'. To use some lldb program other than those, change the value.
let g:lldb_program = 'some-other-lldb-that-you-use'
```
