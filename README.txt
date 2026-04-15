reading.vim

a reading environment for vim, built on goyo.vim

features
  - paragraph numbers in the left margin (textnr)
  - wiktionary + local dictionary lookup in a popup
  - word list of recent lookups in the right margin

requires
  - vim 9.0+
  - goyo.vim  https://github.com/junegunn/goyo.vim

install
  copy or symlink to pack/plugins/start/reading.vim

  or as a git submodule:
    git submodule add <url> pack/plugins/start/reading.vim

mappings
  nmap yoN <Plug>(TextNrToggle)
  nmap yoW <Plug>(WiktListToggle)
  nmap K <Plug>(WiktLookup)
  xmap K <Plug>(WiktLookup)

see :help reading.txt for full documentation
