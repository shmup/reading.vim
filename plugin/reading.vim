if !has('vim9script') || v:version < 900
    finish
endif

vim9script noclear

# reading mode orchestrator
# sets up keymaps, syntax, and highlights when goyo enters
# tears them down when goyo leaves

var enabled = false
var saved_K_n: dict<any> = {}
var saved_K_x: dict<any> = {}
var upper_prop = 'reading_upper_hl'
var upper_prop_initialized = false

def ApplyUppercaseProps()
    prop_remove({type: upper_prop, all: true})
    for lnum in range(1, line('$'))
        var text = getline(lnum)
        if text =~ '\S' && text =~ '^[^a-z]*$'
            prop_add(lnum, 1, {
                type: upper_prop,
                length: len(text),
            })
        endif
    endfor
enddef

def Toggle()
    Goyo
enddef

def Enable()
    if enabled
        return
    endif
    enabled = true

    # save existing K mappings so we can restore on leave
    saved_K_n = maparg('K', 'n', false, true)
    saved_K_x = maparg('K', 'x', false, true)

    # K looks up word definition
    nmap <silent> K <Plug>(WiktLookup)
    xmap <silent> K <Plug>(WiktLookup)

    # uppercase-only lines rendered as comments (text properties survive clearmatches)
    if !upper_prop_initialized
        prop_type_add(upper_prop, {highlight: 'Comment'})
        upper_prop_initialized = true
    endif
    ApplyUppercaseProps()

    silent TextNrToggle
    silent WiktListToggle
enddef

def Disable()
    if !enabled
        return
    endif
    enabled = false

    # restore original K mappings or remove ours
    if !saved_K_n->empty()
        mapset('n', false, saved_K_n)
    else
        silent! nunmap K
    endif
    if !saved_K_x->empty()
        mapset('x', false, saved_K_x)
    else
        silent! xunmap K
    endif
    saved_K_n = {}
    saved_K_x = {}

    # remove uppercase highlight
    prop_remove({type: upper_prop, all: true})
enddef

command ReadingToggle Toggle()
nnoremap <Plug>(ReadingToggle) <ScriptCmd>Toggle()<CR>

augroup ReadingMode
    autocmd!
    autocmd User GoyoEnter Enable()
    autocmd User GoyoLeave Disable()
    autocmd BufEnter * if enabled | ApplyUppercaseProps() | endif
augroup END
