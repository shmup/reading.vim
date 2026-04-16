if !has('vim9script') || v:version < 900
    finish
endif

vim9script noclear

# show line numbers only on non-empty lines
# renders numbers in goyo's left padding window

var enabled = false
var source_bufnr = -1
var textnrs: dict<number> = {}
var nr_to_lnum: dict<number> = {}
var max_nr = 0
var prop_name = 'textnr_hl'
var prop_initialized = false
var last_w0 = -1
var last_w_last = -1
var saved_cr_c: dict<any> = {}
var saved_scrollup_n: dict<any> = {}
var saved_scrolldown_n: dict<any> = {}

def ComputeNumbers()
    textnrs = {}
    nr_to_lnum = {}
    var nr = 0
    for lnum in range(1, line('$'))
        if getline(lnum) =~ '\S'
            nr += 1
            textnrs[string(lnum)] = nr
            nr_to_lnum[string(nr)] = lnum
        endif
    endfor
    max_nr = nr
enddef

def UpdatePad()
    if !exists('t:goyo_pads') || bufnr() != source_bufnr
        return
    endif

    var pad_bufnr = t:goyo_pads.l
    var pad_winid = bufwinid(pad_bufnr)
    if pad_winid == -1
        return
    endif

    var main_winid = win_getid()
    var pad_width = winwidth(win_id2win(pad_winid))
    var first = line('w0')
    var last = min([line('w$') + 1, line('$')])
    var win_height = winheight(0)

    # skip redraw if viewport unchanged (avoids blink from unrelated scroll)
    if first == last_w0 && last == last_w_last
        win_execute(pad_winid, 'normal! gg')
        return
    endif
    last_w0 = first
    last_w_last = last

    # build pad lines, accounting for wrapped lines
    var pad_lines: list<string> = []
    var row = 0
    for lnum in range(first, last)
        if row >= win_height
            break
        endif

        # figure out how many screen rows this line takes
        var pos_this = screenpos(main_winid, lnum, 1)
        var screen_rows = 1
        if lnum < last
            var pos_next = screenpos(main_winid, lnum + 1, 1)
            if pos_next.row > 0 && pos_this.row > 0
                screen_rows = max([1, pos_next.row - pos_this.row])
            endif
        else
            screen_rows = max([1, win_height - row])
        endif

        # first screen row gets the number (if any), rest are blank
        var label = ''
        if textnrs->has_key(string(lnum))
            label = printf($'%{pad_width - 1}d', textnrs[string(lnum)])
        endif
        pad_lines->add(label)
        row += 1

        for _ in range(1, screen_rows - 1)
            if row >= win_height
                break
            endif
            pad_lines->add('')
            row += 1
        endfor
    endfor

    # fill remaining rows
    pad_lines->extend(repeat([''], win_height - len(pad_lines)))

    # write to pad buffer and highlight numbers
    setbufvar(pad_bufnr, '&modifiable', 1)
    setbufline(pad_bufnr, 1, pad_lines)
    var old_count = getbufinfo(pad_bufnr)[0].linecount
    if old_count > len(pad_lines)
        deletebufline(pad_bufnr, len(pad_lines) + 1, '$')
    endif

    # add text properties to highlight the numbers
    prop_remove({type: prop_name, bufnr: pad_bufnr, all: true})
    for i in range(1, len(pad_lines))
        var line = pad_lines[i - 1]
        var num_match = matchstrpos(line, '\d\+')
        if num_match[1] >= 0
            prop_add(i, num_match[1] + 1, {
                type: prop_name,
                bufnr: pad_bufnr,
                length: len(num_match[0]),
            })
        endif
    endfor

    setbufvar(pad_bufnr, '&modifiable', 0)
    win_execute(pad_winid, 'normal! gg')
    win_execute(pad_winid, 'setlocal nowrap')
    redraw
enddef

def Refresh()
    if bufnr() != source_bufnr
        return
    endif
    ComputeNumbers()
    last_w0 = -1
    last_w_last = -1
    UpdatePad()
enddef

def OnResize()
    # re-trigger Goyo layout so padding adjusts to new terminal size
    if exists('t:goyo_dim_expr') && !empty(t:goyo_dim_expr)
        execute 'Goyo ' .. t:goyo_dim_expr
    endif
    Refresh()
enddef

def Disable()
    if !enabled
        return
    endif
    enabled = false
    source_bufnr = -1
    last_w0 = -1
    last_w_last = -1
    if !saved_cr_c->empty()
        mapset('c', false, saved_cr_c)
    else
        silent! cunmap <CR>
    endif
    if !saved_scrollup_n->empty()
        mapset('n', false, saved_scrollup_n)
    else
        silent! nunmap <ScrollWheelUp>
    endif
    if !saved_scrolldown_n->empty()
        mapset('n', false, saved_scrolldown_n)
    else
        silent! nunmap <ScrollWheelDown>
    endif
    saved_cr_c = {}
    saved_scrollup_n = {}
    saved_scrolldown_n = {}
    augroup TextNr
        autocmd!
    augroup END
    # clear the pad (fill with blanks so no ~ tildes show)
    if exists('t:goyo_pads')
        var pad_bufnr = t:goyo_pads.l
        var pad_winid = bufwinid(pad_bufnr)
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
    endif
enddef

def TranslateCmd(): string
    if !enabled || getcmdtype() != ':'
        return "\<CR>"
    endif
    var cmd = getcmdline()
    if cmd =~ '^\d\+$'
        var nr = str2nr(cmd)
        if nr >= 1
            var target = min([nr, max_nr])
            if nr_to_lnum->has_key(string(target))
                return $"\<C-U>{nr_to_lnum[string(target)]}\<CR>"
            endif
        endif
    endif
    return "\<CR>"
enddef

def RedirectScroll(motion: string, count: number)
    if !exists('t:goyo_pads')
        execute $'normal! {count}{motion}'
        return
    endif
    var mpos = getmousepos()
    var right_pad = bufwinid(t:goyo_pads.r)
    if mpos.winid == right_pad
        # scroll right pad, but clamp so blanks don't scroll into view
        if motion == "\<C-e>"
            var info = getwininfo(right_pad)[0]
            var lines = getbufline(t:goyo_pads.r, info.botline, '$')
            if lines->indexof((_, v) => v =~ '\S') >= 0
                win_execute(right_pad, $'normal! {count}{motion}')
            endif
        else
            win_execute(right_pad, $'normal! {count}{motion}')
        endif
    else
        # left/top/bottom pads and main window all scroll main content
        execute $'normal! {count}{motion}'
    endif
enddef

def Toggle()
    if enabled
        Disable()
        echo 'textnr off'
    else
        if !exists('t:goyo_pads')
            var w = get(g:, 'goyo_width', 80)
            var h = get(g:, 'goyo_height', '85%')
            execute $'Goyo {w}x{h}'
        endif
        enabled = true
        source_bufnr = bufnr()
        set wrap
        if !prop_initialized
            prop_type_add(prop_name, {highlight: 'LineNr'})
            prop_initialized = true
        endif
        Refresh()
        saved_cr_c = maparg('<CR>', 'c', false, true)
        saved_scrollup_n = maparg('<ScrollWheelUp>', 'n', false, true)
        saved_scrolldown_n = maparg('<ScrollWheelDown>', 'n', false, true)
        cnoremap <expr> <CR> <SID>TranslateCmd()
        execute $'nnoremap <ScrollWheelUp> <ScriptCmd>RedirectScroll("\<C-y>", 3)<CR>'
        execute $'nnoremap <ScrollWheelDown> <ScriptCmd>RedirectScroll("\<C-e>", 3)<CR>'
        augroup TextNr
            autocmd!
            autocmd CursorMoved,WinScrolled * TextNrUpdate
            autocmd VimResized * TextNrResize
            autocmd BufEnter * TextNrRefresh
            autocmd TextChanged,TextChangedI * TextNrRefresh
        augroup END
        echo 'textnr on'
    endif
enddef

command! TextNrToggle Toggle()
command! TextNrUpdate UpdatePad()
command! TextNrRefresh Refresh()
command! TextNrResize OnResize()
nnoremap <Plug>(TextNrToggle) <ScriptCmd>Toggle()<CR>

augroup TextNrGoyo
    autocmd!
    autocmd User GoyoLeave Disable()
augroup END
