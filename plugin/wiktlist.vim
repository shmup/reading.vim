if !has('vim9script') || v:version < 900
    finish
endif

vim9script noclear

# show recently looked-up wiktionary words in goyo's right pad

var enabled = false
var words: list<string> = []
var persist_path = get(g:, 'wiktlist_persist_path', $'{$HOME}/.vim/junk/wikt_words')
var prop_name = 'wiktlist_hl'
var prop_initialized = false
var saved_leftclick_n: dict<any> = {}
var saved_rightclick_n: dict<any> = {}

def LoadWords()
    words = []
    if filereadable(persist_path)
        words = readfile(persist_path)->filter((_, v) => v =~ '\S')->sort('i')
    endif
enddef

def SaveWords()
    var dir = fnamemodify(persist_path, ':h')
    if !isdirectory(dir)
        mkdir(dir, 'p')
    endif
    writefile(words, persist_path)
enddef

def AddWord(word: string)
    if word->empty()
        return
    endif
    var lower = word->tolower()
    if words->indexof((_, w) => w->tolower() == lower) >= 0
        return
    endif
    words->add(word)
    words->sort('i')
    SaveWords()
    if enabled
        UpdatePad()
    endif
enddef

def RemoveWord(word: string)
    if word->empty()
        return
    endif
    var lower = word->tolower()
    var idx = words->indexof((_, w) => w->tolower() == lower)
    if idx < 0
        return
    endif
    words->remove(idx)
    SaveWords()
    if enabled
        UpdatePad()
    endif
enddef

def PadBufnr(): number
    if !exists('t:goyo_pads')
        return -1
    endif
    return t:goyo_pads.r
enddef

def PadWinid(): number
    var bufnr = PadBufnr()
    if bufnr == -1
        return -1
    endif
    return bufwinid(bufnr)
enddef

def UpdatePad()
    var pad_bufnr = PadBufnr()
    var pad_winid = PadWinid()
    if pad_winid == -1
        return
    endif
    var pad_winnr = win_id2win(pad_winid)
    var pad_width = winwidth(pad_winnr)
    var win_height = winheight(pad_winnr)

    var left_pad = pad_width > 15 ? 4 : 1
    var pad_str = repeat(' ', left_pad)
    var pad_lines: list<string> = []
    for word in words
        var display = word
        if strcharlen(display) > pad_width - left_pad
            display = strcharpart(display, 0, pad_width - left_pad - 2) .. '..'
        endif
        pad_lines->add(pad_str .. display)
    endfor
    # pad with blanks if list is shorter than window
    if len(pad_lines) < win_height
        pad_lines->extend(repeat([''], win_height - len(pad_lines)))
    endif

    setbufvar(pad_bufnr, '&modifiable', 1)
    setbufline(pad_bufnr, 1, pad_lines)
    var old_count = getbufinfo(pad_bufnr)[0].linecount
    if old_count > len(pad_lines)
        deletebufline(pad_bufnr, len(pad_lines) + 1, '$')
    endif

    if !prop_initialized
        prop_type_add(prop_name, {highlight: 'LineNr'})
        prop_initialized = true
    endif
    prop_remove({type: prop_name, bufnr: pad_bufnr, all: true})
    for i in range(1, len(pad_lines))
        var line = pad_lines[i - 1]
        if line =~ '\S'
            prop_add(i, left_pad + 1, {
                type: prop_name,
                bufnr: pad_bufnr,
                length: len(line) - left_pad,
            })
        endif
    endfor

    setbufvar(pad_bufnr, '&modifiable', 0)
enddef

def HandleClick()
    var mpos = getmousepos()
    var is_pad = exists('t:goyo_pads') && mpos.winid == PadWinid()
    if !is_pad
        # pass through: position cursor at click
        var pos = getmousepos()
        win_gotoid(pos.winid)
        cursor(pos.line, pos.column)
        return
    endif
    var idx = mpos.line - 1
    if idx < 0 || idx >= len(words)
        return
    endif
    # find main window (not a pad)
    var target_word = words[idx]
    for winnr in range(1, winnr('$'))
        var winid = win_getid(winnr)
        if winid != bufwinid(t:goyo_pads.l) && winid != bufwinid(t:goyo_pads.r)
            win_gotoid(winid)
            break
        endif
    endfor
    # seed wiktionary nav list so left/right arrows cycle all words
    g:wikt_nav_words = copy(words)
    g:wikt_nav_pos = idx
    timer_start(50, (_) => {
        execute 'Define' target_word
    })
enddef

def HandleRightClick()
    var mpos = getmousepos()
    if !exists('t:goyo_pads')
        return
    endif
    var pad_winid = PadWinid()
    if mpos.winid != pad_winid
        return
    endif
    var idx = mpos.line - 1
    if idx < 0 || idx >= len(words)
        return
    endif
    var target_word = words[idx]
    RemoveWord(target_word)
    echo $'removed "{target_word}"'
enddef

def Disable()
    if !enabled
        return
    endif
    enabled = false
    if !saved_leftclick_n->empty()
        mapset('n', false, saved_leftclick_n)
    else
        silent! nunmap <LeftMouse>
    endif
    if !saved_rightclick_n->empty()
        mapset('n', false, saved_rightclick_n)
    else
        silent! nunmap <RightMouse>
    endif
    saved_leftclick_n = {}
    saved_rightclick_n = {}
    augroup WiktListDisplay
        autocmd!
    augroup END
    var pad_bufnr = PadBufnr()
    var pad_winid = PadWinid()
    if pad_winid != -1
        var h = winheight(win_id2win(pad_winid))
        setbufvar(pad_bufnr, '&modifiable', 1)
        prop_remove({type: prop_name, bufnr: pad_bufnr, all: true})
        setbufline(pad_bufnr, 1, repeat([''], h))
        var old_count = getbufinfo(pad_bufnr)[0].linecount
        if old_count > h
            deletebufline(pad_bufnr, h + 1, '$')
        endif
        setbufvar(pad_bufnr, '&modifiable', 0)
    endif
enddef

def Toggle()
    if enabled
        Disable()
        echo 'wiktlist off'
    else
        if !exists('t:goyo_pads')
            var w = get(g:, 'goyo_width', 80)
            var h = get(g:, 'goyo_height', '85%')
            execute $'Goyo {w}x{h}'
        endif
        enabled = true
        set wrap
        UpdatePad()
        saved_leftclick_n = maparg('<LeftMouse>', 'n', false, true)
        saved_rightclick_n = maparg('<RightMouse>', 'n', false, true)
        nnoremap <LeftMouse> <ScriptCmd>HandleClick()<CR>
        nnoremap <RightMouse> <ScriptCmd>HandleRightClick()<CR>
        augroup WiktListDisplay
            autocmd!
            autocmd VimResized * WiktListUpdate
        augroup END
        echo 'wiktlist on'
    endif
enddef

# always persist lookups, even when display is off
LoadWords()
augroup WiktListPersist
    autocmd!
    autocmd User WiktLookup AddWord(get(g:, 'wikt_last_lookup', ''))
augroup END

command! WiktListToggle Toggle()
command! WiktListUpdate UpdatePad()
command! WiktListDisable Disable()
nnoremap <Plug>(WiktListToggle) <ScriptCmd>Toggle()<CR>

augroup WiktListGoyo
    autocmd!
    autocmd User GoyoLeave Disable()
augroup END
