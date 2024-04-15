if !has('nvim') && !has('terminal')
  "echohl WarningMsg
  "echomsg 'lldb integration requires vim to be compliled with +terminal'
  "echohl None
  finish
endif

if exists('s:loaded')
  finish
endif
let s:loaded = 1

command -bang Lldb call lldb#StartDebug(<bang>0, '', <q-mods>, <f-args>)

" vim:sts=2:sw=2:et:
