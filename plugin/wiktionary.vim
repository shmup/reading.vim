if !has('vim9script') || v:version < 900
    finish
endif

vim9script noclear

# wiktionary definitions in a popup

var api_url = 'https://en.wiktionary.org/api/rest_v1/page/definition/'
var history: dict<list<dict<any>>> = {}
var hist_pos: dict<number> = {}
var source_match_id: number = 0
var current_popup: number = 0

# local dictionaries: pipe-delimited files checked before wiktionary
# set g:wikt_dictionaries = [{path: '...', name: '...'}, ...]
var dict_sources: list<dict<string>> = get(g:, 'wikt_dictionaries', [])
var dict_cache: dict<dict<string>> = {}
# maps singular forms found in "(singular X)" to their plural entry key
var dict_aliases: dict<dict<string>> = {}
# maps lowercase key → original-cased entry name
var dict_names: dict<dict<string>> = {}

def LoadDict(filepath: string): dict<string>
    if dict_cache->has_key(filepath)
        return dict_cache[filepath]
    endif
    var entries: dict<string> = {}
    var aliases: dict<string> = {}
    var names: dict<string> = {}
    if !filereadable(filepath)
        return entries
    endif
    for line in readfile(filepath)
        var bar = line->stridx('|')
        if bar < 0
            continue
        endif
        var key = strcharpart(line, 0, charidx(line, bar))
        var def = line[bar + 1 :]
        entries[key->tolower()] = def
        names[key->tolower()] = key
        # extract "(singular X)" and map X back to this entry
        var singular = def->matchstr('(singular \zs[^)]\+\ze)')
        if !singular->empty()
            aliases[singular->tolower()] = key->tolower()
        endif
    endfor
    dict_cache[filepath] = entries
    dict_aliases[filepath] = aliases
    dict_names[filepath] = names
    return entries
enddef

def LookupLocal(word: string): list<string>
    var lower = word->tolower()
    var lines: list<string> = []
    for src in dict_sources
        var entries = LoadDict(src.path)
        var key = lower
        if !entries->has_key(key)
            # check if this is a known singular form
            var aliases = dict_aliases->get(src.path, {})
            if aliases->has_key(key)
                key = aliases[key]
            else
                continue
            endif
        endif
        if lines->empty()
            var title = dict_names->get(src.path, {})->get(key, word)
            lines->add(title)
            lines->add('')
        endif
        lines->add(src.name)
        lines->add($'    {entries[key]}')
        lines->add('')
    endfor
    if !lines->empty() && lines[-1]->empty()
        lines->remove(-1)
    endif
    return lines
enddef

highlight WiktSource ctermbg=white ctermfg=black guibg=white guifg=black

def StripHtml(raw: string): string
    return raw
        ->substitute('<style[^>]*>.\{-}</style>', '', 'g')
        ->substitute('<[^>]*>', '', 'g')
        ->substitute('&nbsp;', ' ', 'g')
        ->substitute('&amp;', '\&', 'g')
        ->substitute('&lt;', '<', 'g')
        ->substitute('&gt;', '>', 'g')
        ->substitute('&quot;', '"', 'g')
        ->substitute('&#39;', "'", 'g')
        ->substitute('\.mw-parser-output[^}]*}', '', 'g')
        ->substitute('\n', ' ', 'g')
        ->substitute('  *', ' ', 'g')
        ->substitute('^ *\| *$', '', 'g')
enddef

def FormatResponse(word: string, body: string): list<string>
    var lines: list<string> = []
    var data: dict<any>

    try
        data = json_decode(body)
    catch
        return [$'could not parse response for "{word}"']
    endtry

    if data->get('title', '') == 'Not found.'
        return [$'"{word}" not found']
    endif

    lines->add(word)
    lines->add('')

    for lang_key in data->keys()->sort()
        var entries = data[lang_key]
        if type(entries) != v:t_list
            continue
        endif

        var current_lang = ''
        for usage in entries
            var language = usage->get('language', '')
            var part_of_speech = usage->get('partOfSpeech', '')

            if language != current_lang
                if !lines[-1]->empty()
                    lines->add('')
                endif
                lines->add(language)
                current_lang = language
            endif

            lines->add($'  {part_of_speech}')

            var definitions = usage->get('definitions', [])
            var defnum = 0
            for def_entry in definitions
                var def_html = def_entry->get('definition', '')
                var def_text = StripHtml(def_html)
                if def_text->empty()
                    continue
                endif
                defnum += 1
                lines->add($'  {defnum}. {def_text}')

                var examples = def_entry->get('examples', [])
                for ex in examples
                    var ex_text = StripHtml(ex)
                    if !ex_text->empty()
                        lines->add($'     - {ex_text}')
                    endif
                endfor
            endfor
        endfor
    endfor

    return lines
enddef

def ApplyHighlights(popup_id: number, word: string)
    var bufnr = winbufnr(popup_id)

    prop_type_add('wikt_word', {bufnr: bufnr, highlight: 'Title'})
    prop_add(1, 1, {bufnr: bufnr, type: 'wikt_word', length: word->len()})
    prop_type_add('wikt_lang', {bufnr: bufnr, highlight: 'Statement'})
    prop_type_add('wikt_pos', {bufnr: bufnr, highlight: 'Type'})
    prop_type_add('wikt_example', {bufnr: bufnr, highlight: 'Comment'})
    prop_type_add('wikt_match', {bufnr: bufnr, highlight: 'Underlined'})
    var all_lines = getbufline(bufnr, 1, '$')
    var pat = $'\c\V{word->escape('\')}'
    for i in all_lines->len()->range()
        var line = all_lines[i]
        var lnum = i + 1
        if line =~ '^\S' && lnum > 1
            # language header
            prop_add(lnum, 1, {bufnr: bufnr, type: 'wikt_lang',
                length: line->len()})
        elseif line =~ '^  \S' && line !~ '^  \d'
            # part of speech
            prop_add(lnum, 3, {bufnr: bufnr, type: 'wikt_pos',
                length: line->len() - 2})
        elseif line =~ '^     - '
            # example
            prop_add(lnum, 6, {bufnr: bufnr, type: 'wikt_example',
                length: line->len() - 5})
        endif
        # highlight occurrences of the looked-up word in definition lines
        if lnum > 2
            var start = 0
            while true
                var m = line->matchstrpos(pat, start)
                if m[1] < 0
                    break
                endif
                prop_add(lnum, m[1] + 1, {
                    bufnr: bufnr,
                    type: 'wikt_match',
                    length: len(m[0]),
                })
                start = m[2]
            endwhile
        endif
    endfor
enddef

def WordAtCol(text: string, col: number): string
    var chars = text->split('\zs')
    var i = col - 1
    if i < 0 || i >= chars->len() || chars[i] !~ '\k'
        return ''
    endif
    var s = i
    while s > 0 && chars[s - 1] =~ '\k'
        s -= 1
    endwhile
    var e = i + 1
    while e < chars->len() && chars[e] =~ '\k'
        e += 1
    endwhile
    return chars[s : e - 1]->join('')
enddef

def RecordLookup(word: string, lines: list<string>)
    var key = expand('%:p')
    if !history->has_key(key)
        history[key] = []
        hist_pos[key] = -1
    endif
    # skip if same word as current entry
    if !history[key]->empty() && hist_pos[key] >= 0
        && history[key][hist_pos[key]].word ==? word
        return
    endif
    # truncate forward history (browser-style)
    if hist_pos[key] < history[key]->len() - 1
        history[key] = history[key][: hist_pos[key]]
    endif
    history[key]->add({word: word, lines: lines})
    hist_pos[key] = history[key]->len() - 1
enddef

var nav_active = false

def NavigateHistory(popup_id: number, delta: number)
    # external nav list (from wiktlist pad)
    if exists('g:wikt_nav_words') && !g:wikt_nav_words->empty()
        var nav = g:wikt_nav_words
        var pos = get(g:, 'wikt_nav_pos', 0) + delta
        # wrap around
        if pos < 0
            pos = len(nav) - 1
        elseif pos >= len(nav)
            pos = 0
        endif
        g:wikt_nav_pos = pos
        nav_active = true
        popup_close(popup_id)
        nav_active = false
        LookupWord(nav[pos])
        return
    endif

    var key = expand('%:p')
    if !history->has_key(key)
        return
    endif
    var pos = hist_pos[key] + delta
    if pos < 0 || pos >= history[key]->len()
        return
    endif
    hist_pos[key] = pos
    popup_close(popup_id)
    var entry = history[key][pos]
    ShowPopup(entry.lines, entry.word)
enddef

def PopupFilter(id: number, key: string): bool
    if key == "\<LeftMouse>"
        var mpos = getmousepos()
        if mpos.winid != id
            popup_close(id)
            return false
        endif
        var blines = getbufline(winbufnr(id), mpos.line, mpos.line)
        if blines->empty()
            return true
        endif
        var clicked = WordAtCol(blines[0], blines[0]->charidx(mpos.column - 1) + 1)
        if !clicked->empty()
            LookupWord(clicked)
        endif
        return true
    elseif key == "\<LeftRelease>" || key == "\<LeftDrag>" || key == "\<2-LeftMouse>"
        return getmousepos().winid == id
    elseif key == 'j' || key == "\<C-j>" || key == "\<Down>"
        var info = popup_getpos(id)
        var total = getbufline(winbufnr(id), 1, '$')->len()
        if info.lastline < total
            win_execute(id, "normal! \<C-e>")
        endif
        return true
    elseif key == 'k' || key == "\<C-k>" || key == "\<Up>"
        if popup_getpos(id).firstline > 1
            win_execute(id, "normal! \<C-y>")
        endif
        return true
    elseif key == 'd' || key == "\<C-d>"
        var info = popup_getpos(id)
        var total = getbufline(winbufnr(id), 1, '$')->len()
        if info.lastline < total
            win_execute(id, $"normal! {&scroll}\<C-e>")
        endif
        return true
    elseif key == 'u' || key == "\<C-u>"
        if popup_getpos(id).firstline > 1
            win_execute(id, $"normal! {&scroll}\<C-y>")
        endif
        return true
    elseif key == 'h' || key == "\<Left>"
        NavigateHistory(id, -1)
        return true
    elseif key == 'l' || key == "\<Right>"
        NavigateHistory(id, 1)
        return true
    elseif key == 'q' || key == "\<Esc>"
        popup_close(id)
        return true
    endif
    return false
enddef

def WrapLines(lines: list<string>, width: number): list<string>
    var result: list<string> = []
    for line in lines
        if line->len() <= width || line->trim()->empty()
            result->add(line)
            continue
        endif
        # find indent of this line for continuation
        var indent = line->matchstr('^ *')
        var rest = line[indent->len() :]
        var cur = indent
        for word in rest->split('\s\+')
            if cur->len() + word->len() + 1 > width && cur != indent
                result->add(cur)
                cur = indent .. '  ' .. word
            elseif cur == indent
                cur ..= word
            else
                cur ..= ' ' .. word
            endif
        endfor
        if cur != indent
            result->add(cur)
        endif
    endfor
    return result
enddef

def ClearSourceHighlight(id: number, result: number)
    if source_match_id > 0
        silent! matchdelete(source_match_id)
        source_match_id = 0
    endif
    current_popup = 0
    if !nav_active && id > 0
        silent! unlet g:wikt_nav_words
        silent! unlet g:wikt_nav_pos
    endif
enddef

def ShowPopup(lines: list<string>, word: string)
    if current_popup > 0
        popup_close(current_popup)
        current_popup = 0
    endif
    ClearSourceHighlight(0, 0)
    source_match_id = matchadd('WiktSource', $'\V{word->escape('\')}\m')

    # border (2) + padding (2) + margin; cap at 80 for readability
    var maxwidth = min([max([&columns - 6, 24]), 80])
    var wrapped = WrapLines(lines, maxwidth)

    # show below cursor if more room there, above otherwise
    var above = winline() - 1
    var below = &lines - winline()
    var pos = below >= above ? 'topleft' : 'botleft'

    var popup_id = popup_atcursor(wrapped, {
        pos: pos,
        border: [],
        padding: [0, 1, 0, 1],
        minwidth: wrapped->mapnew((_, l) => l->len())->max(),
        maxwidth: maxwidth,
        maxheight: &lines - 4,
        scrollbar: true,
        highlight: 'Normal',
        borderHighlight: ['Normal'],
        filter: PopupFilter,
        callback: ClearSourceHighlight,
    })
    current_popup = popup_id
    ApplyHighlights(popup_id, word)
enddef

def LookupWord(word: string)
    if word->empty()
        echo 'no word to define'
        return
    endif

    var local = LookupLocal(word)
    if !local->empty()
        RecordLookup(word, local)
        g:wikt_last_lookup = word
        silent doautocmd User WiktLookup
        ShowPopup(local, word)
        return
    endif

    var encoded = word->substitute(' ', '%20', 'g')
    var url = api_url .. encoded
    var output_lines: list<string> = []

    job_start(['curl', '-s', url], {
        out_cb: (_, msg) => {
            output_lines->add(msg)
        },
        exit_cb: (_, status) => {
            timer_start(0, (_) => {
                if status != 0
                    ShowPopup([$'request failed for "{word}"'], word)
                    return
                endif
                var body = output_lines->join("\n")
                var lines = FormatResponse(word, body)
                if lines->len() <= 2
                    echo $'no definition found for "{word}"'
                    return
                endif
                RecordLookup(word, lines)
                g:wikt_last_lookup = word
                silent doautocmd User WiktLookup
                ShowPopup(lines, word)
            })
        },
    })
enddef

def DefineVisual()
    var saved = getreg('"')
    normal! gvy
    var selected = getreg('"')
    setreg('"', saved)
    selected = selected->substitute('\n', ' ', 'g')->trim()
    LookupWord(selected)
enddef

command! -nargs=+ Define LookupWord(<q-args>)
nnoremap <Plug>(WiktLookup) <ScriptCmd>LookupWord(expand('<cword>'))<CR>
xnoremap <Plug>(WiktLookup) <ScriptCmd>DefineVisual()<CR>
