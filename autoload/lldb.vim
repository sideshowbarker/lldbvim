if exists('s:loaded')
  finish
endif
let s:loaded = 1
let s:debug = v:false
"let s:debug = v:true

let s:job_id = 0
let s:ptybuf = 0
let s:dbgwin = 0

func! s:splitdrive(p)
  if a:p[1:1] ==# ':'
    return [a:p[0:1], a:p[2:]]
  endif
  return ['', a:p]
endfunc

func! s:isabs(s)
  if has('unix')
    return a:s =~# '^/'
  else
    let s = s:splitdrive(a:s)[1]
    return s !=# '' && s[0:0] =~# '/\|\\'
  endif
endfunc

func! s:GetCmdOutput(sCmd)
    let bak_lang = v:lang

    " 把消息统一为英文
    exec ":lan mes en_US.UTF-8"

    try
        redir => sOutput
        silent! exec a:sCmd
    catch
        " 把错误消息设置为最后的 ':' 后的字符串?
        "let v:errmsg = substitute(v:exception, '^[^:]\+:', '', '')
    finally
        redir END
    endtry

    exec ":lan mes " . bak_lang

    return sOutput
endfunc

let s:cache_lines = []
" for debug
let lldb#cache_lines = s:cache_lines
" {lldbBreakpointNumber: {lineNumber: ..., file: ...}, ...}
let s:breakpoints = {}

hi default link LldbBreak NonText

function! s:InitVariable(var, value, ...)
  let force = a:0 > 0 ? a:1 : 0
  if force || !exists(a:var)
    if exists(a:var)
      unlet {a:var}
    endif
    let {a:var} = a:value
  endif
endfunction

" 启动时是否使用 shell
call s:InitVariable('g:lldb_use_shell', 0)
if &filetype=='rust'
  call s:InitVariable('g:lldb_program', 'rust-lldb')
else
  call s:InitVariable('g:lldb_program', 'lldb')
endif

" (bang, type, *argv)
function lldb#StartDebug(bang, type, mods, ...) abort
  if s:dbgwin > 0
    echoerr 'lldb is already running'
    return
  endif

  let s:startwin = win_getid(winnr())
  let s:startsigncolumn = &signcolumn

  let argv = copy(a:000)
  " 使用 shell 来运行调试器的话，可以避免一些奇怪问题，主要是环境变量问题
  if g:lldb_use_shell
    let argv = [&shell, &shellcmdflag] + [join(map(argv, {idx, val -> shellescape(val)}), ' ')]
  endif

  exec a:mods "new lldb"
  if has('nvim')
    let callbacks = {
      \ 'on_stdout': function('s:on_event'),
      \ 'on_stderr': function('s:on_event'),
      \ 'on_exit': function('s:on_event')
      \ }
    let s:ptybuf = bufnr('%')
    let s:job_id = termopen(argv, extend({}, callbacks))
  else
    let s:ptybuf = term_start(g:lldb_program, {
          \ 'term_name': 'lldb',
          \ 'out_cb': function('lldb#on_stdout'),
          \ 'err_cb': function('s:on_stderr'),
          \ 'exit_cb': function('s:on_exit'),
          \ 'term_finish': 'close',
          \ 'curwin': v:true,
          \ })
  endif
  let s:dbgwin = win_getid(winnr())

  call s:InstallCommands()
  call win_gotoid(s:startwin)
  stopinsert

  " Sign used to indicate a breakpoint.
  " Can be used multiple times.
  sign define LldbBreak text=■▶ texthl=LldbBreak

  augroup Lldb
    autocmd BufRead * call s:BufRead()
    autocmd BufUnload * call s:BufUnloaded()
  augroup END

  " 初始跳到调试窗口，以方便输入命令，然而，回调会重定位光标
  call win_gotoid(s:ptybuf)
endfunction

" 只要在终端窗口一定时间内（n毫秒）有连续的输出，就会进入此回调
" 不保证 msg 是一整行
" 因为绝大多数程序的标准输出是行缓冲的，所以一般情况下（手动输入除外），
" msg 是成整行的，可能是多个整行
" BUG: 虽然 msg 每次过来基本可以确定是整行的，但是行之间的顺序是不定的！
" ...
" The purpose of this function is to retrieve the breakpoint number that
" lldb assigns each time we send it a “breakpoint set” command.
function lldb#on_stdout(job_id, msg)
  let lines = split(a:msg, "\r")
  for idx in range(len(lines))
    " 去除 "^\n"
    let lines[idx] = substitute(lines[idx], '^\n', '', '')
  endfor

  call extend(s:cache_lines, lines)
  if len(s:cache_lines) > 100
    call filter(s:cache_lines, {idx, val -> idx >= len(s:cache_lines) - 100})
  endif

  " 无脑逐行匹配动作！
  for line in reverse(lines)
    call s:dbg(line)
    if line =~# '^Breakpoint \d\+: '
      " We sent a “breakpoint set” command to lldb, and lldb responded with
      " a “Breakpoint (\d+)” message that includes a breakpoint number.
      call s:HandleNewBreakpoint(line)
    endif
  endfor
endfunction

func s:HandleNewBreakpoint(msg)
  " The lldb “Breakpoint (\d+)” message may or may not cite a file name
  " and line number — but it does always include a breakpoint number,
  " which is anyway all that we need.
  let matches = matchlist(a:msg, '\v^Breakpoint (\d+): ')
  call s:dbg(matches)
  let lldbBreakpointNumber = get(matches, 1, 0)

  if has_key(s:breakpoints, lldbBreakpointNumber)
    let entry = s:breakpoints[lldbBreakpointNumber]
  else
    let entry = {}
    let s:breakpoints[lldbBreakpointNumber] = entry
  endif
  " Absolute path to file open in the current buffer in vim.
  let entry['file'] = expand('%:p')
  " Line number of the line where the cursor currently is in vim.
  let entry['lineNumber'] = line('.')

  call s:PlaceSign(lldbBreakpointNumber, entry)
endfunc

func s:PlaceSign(lldbBreakpointNumber, entry)
  exe 'sign place ' . a:lldbBreakpointNumber . ' line=' . line('.') . ' name=LldbBreak file=' . expand('%:p')
  let a:entry['placed'] = 1
endfunc

func s:on_event(job_id, data, event) dict abort
  if a:event == 'stdout'
    call lldb#on_stdout(a:job_id, join(a:data, "\n"))
  elseif a:event == 'stderr'
    call s:on_stderr(a:job_id, join(a:data, "\n"))
  else " 'exit'
    call s:on_exit(a:job_id, a:data)
  endif
endfunc

function s:on_stderr(job_id, data)
endfunction

function s:on_exit(job_id, status)
  execute 'bwipe!' s:ptybuf
  let s:ptybuf = 0
  let s:dbgwin = 0
  call filter(s:cache_lines, 0)

  let curwinid = win_getid(winnr())

  if win_gotoid(s:startwin)
    let &signcolumn = s:startsigncolumn
  endif

  call s:DeleteCommands()
  call sign_unplace('*', {'group' : 'Lldb'})

  sign undefine LldbBreak
  call filter(s:breakpoints, 0)

  autocmd! Lldb
endfunction

function s:getbufmaxline(bufnr)
  if has('nvim')
    return nvim_buf_line_count(a:bufnr)
  else
    return pyxeval('len(vim.buffers['.(a:bufnr).'])')
  endif
endfunction

" nvim 有 BUG, 在终端窗口跳去其他窗口开启 scrolloff, 跳到指定行后, scrolloff 无效
function s:RefreshScrolloff()
  let off = &scrolloff
  if off <= 0
    return
  endif
  let wline = winline()
  let wheight = winheight(0)
  if wline < off
    exec 'normal!' "z\<CR>"
  elseif wline > wheight - off
    normal! zb
  endif
endfunction

func s:InstallCommands()
  command LToggleBreakpoint call s:ToggleBreakpoint()
  command LDeleteAllBreakpoints call lldb#DeleteAllBreakpoints()
endfunc

func s:DeleteCommands()
  delcommand LToggleBreakpoint
  delcommand LDeleteAllBreakpoints
endfunc

func s:SendCommand(cmd)
  if has('nvim')
    if s:job_id > 0
      call jobsend(s:job_id, "\<C-u>")
      call jobsend(s:job_id, a:cmd . "\r")
    endif
  else
    call term_sendkeys(s:ptybuf, "\<C-u>")
    call term_sendkeys(s:ptybuf, a:cmd . "\r")
  endif
endfunc

func s:SetBreakpoint()
  " Tell lldb to set a breakpoint at the current line in the file that’s
  " open in the current buffer in vim.
  call s:SendCommand(printf('breakpoint set -f %s -l %d', fnameescape(expand('%:p')), line('.')))
endfunc

func lldb#ClearBreakpoint()
  for [lineNumber, entry] in items(s:breakpoints)
    " If there’s an entry for the filename and line number at which the
    " cursor currently is in vim...
    if entry['file'] ==# expand('%:p') && entry['lineNumber'] == line('.')
      call s:SendCommand(printf('%s %s', 'breakpoint delete', lineNumber))
      " lldb 无法使用兜底的确认机制, 这里就直接删除
      if get(entry, 'placed', 0)
        execute 'sign unplace ' . lineNumber
        let entry['placed'] = 0
      endif
      unlet s:breakpoints[lineNumber]
      break
    endif
  endfor
endfunc

func lldb#DeleteAllBreakpoints()
  if !empty(s:breakpoints)
    " In lldb, “breakpoint delete” with no args = “delete all breakpoints”
    call s:SendCommand(printf('breakpoint delete'))
    " About to delete all breakpoints, do you want to do that?: [Y/n]
    call s:SendCommand(printf('y'))
    call sign_unplace('*', {'group' : 'Lldb'})
    call filter(s:breakpoints, 0)
  endif
endfunc

" 仅列出当前缓冲区的标号
func lldb#sign_getplaced() abort
  let result = []
  let li = split(s:GetCmdOutput('sign place buffer=' . bufnr('%')), "\n")
  for line in li[2:]
    let fields = split(line)
    " vim 8.1 之后，增加了 priority 字段，所以分隔后，字段数可能为 4
    if len(fields) < 3
      continue
    endif
    let entry = {}
    for field in fields
      let ret = matchlist(field, '\(^\w\+\)=\(.\+\)$')
      let key = ret[1]
      let val = ret[2]
      if key ==# 'line' || key ==# 'id' || key ==# 'priority'
        let entry[key] = str2nr(val)
      else
        let entry[key] = val
      endif
    endfor
    " 输出的是 line，后面标准化的时候是 lineNumber
    let entry['lineNumber'] = get(entry, 'line', 0)
    call add(result, entry)
  endfor
  return result
endfunc

func s:ToggleBreakpoint()
  let found = 0
  let li = lldb#sign_getplaced()
  for entry in li
    if get(entry, 'name') ==# 'LldbBreak' && get(entry, 'lineNumber', 0) is line('.')
      let found = 1
      break
    endif
  endfor
  if found
    call lldb#ClearBreakpoint()
  else
    call s:SetBreakpoint()
  endif
endfunc

function lldb#SendCommand(cmd)
  call s:SendCommand(a:cmd)
endfunction

" Handle a BufRead autocommand event: place any signs.
func s:BufRead()
  let file = expand('<afile>:p')
  for [lldbBreakpointNumber, entry] in items(s:breakpoints)
    if entry['file'] ==# file
      call s:PlaceSign(lldbBreakpointNumber, entry)
    endif
  endfor
endfunc

" Handle a BufUnloaded autocommand event: unplace any signs.
func s:BufUnloaded()
  let file = expand('<afile>:p')
  for [lldbBreakpointNumber, entry] in items(s:breakpoints)
    if entry['file'] == file
      let entry['placed'] = 0
    endif
  endfor
endfunc

func s:dbg(...)
  if !s:debug
    return
  endif
  let li = copy(a:000)
  let li = map(li, {_, j -> string(j)})
  echomsg join(li, ' ')
endfunc

" vi:set sts=2 sw=2 et:
