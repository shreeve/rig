# Editor support for Rig

Syntax highlighting for Rig in VS Code, Vim, and highlight.js, and a
language server, `rig lsp`, for any editor that speaks the Language
Server Protocol. The grammars are generated from `rig.grammar` by Nexus
(`nexus --highlight`), from its `@highlight` section; don't edit a
generated file by hand. Each starts with a header naming the grammar it
came from.

| Directory | What it is |
|---|---|
| `vscode/` | A VS Code extension: `syntaxes/rig.tmLanguage.json` and `language-configuration.json` (generated), `package.json`, and `extension.js`, the language server's client |
| `vim/` | A Vim plugin: `syntax/rig.vim` (generated), `ftdetect/rig.vim`, `ftplugin/rig.vim` |
| `highlightjs/` | `rig.js`, a highlight.js language module (generated) |

## After a change to rig.grammar

Run these from the top of the repository, with Nexus checked out beside
it (`../nexus`).

1. Regenerate the editor files:

   ```sh
   ../nexus/bin/nexus --highlight all rig.grammar editors
   ```

2. Check that all three colour the sample as `sample.rig.hl` says (the
   TextMate grammar through a vscode-textmate reference, the highlight.js
   language, and Vim itself). With `--update` first, the check rewrites
   `sample.rig.hl` from the TextMate colouring; review that diff:

   ```sh
   python3 ../nexus/test/lib/highlight ../nexus/docs/GRAMMAR.md \
     editors/vscode/syntaxes/rig.tmLanguage.json editors/highlightjs/rig.js \
     editors/vim/syntax/rig.vim test/highlight/sample.rig test/highlight/sample.rig.hl
   ```

3. Package the VS Code extension. To install it as a newer version, bump
   `"version"` in `editors/vscode/package.json` first. `npm install`
   fetches the client library the package holds
   (`vscode-languageclient`) into `node_modules/`, which is not
   committed:

   ```sh
   cd editors/vscode && npm install && npx -y @vscode/vsce package --skip-license
   ```

4. Install it, then run **Developer: Reload Window** in VS Code:

   ```sh
   code --install-extension editors/vscode/vscode-rig-0.2.0.vsix --force
   ```

The `.vsix` is not committed (`editors/vscode/.gitignore`); rebuild it
from the folder any time.

## Install

- **VS Code:** steps 3 and 4 above. While working on the grammar, a
  symlink is quicker: `ln -s "$PWD/editors/vscode"
  ~/.vscode/extensions/rig-lang.vscode-rig-0.2.0`, then reload the window
  after each regeneration. Use one or the other, not both; the symlinked
  folder needs `npm install` once for its client.
- **Vim:** add `editors/vim` to the runtime path, e.g. with vim-plug:
  `Plug '~/Data/Code/rig', { 'rtp': 'editors/vim' }`, or
  `set runtimepath+=~/Data/Code/rig/editors/vim`.
- **highlight.js:** `import rig from './editors/highlightjs/rig.js'`, then
  `hljs.registerLanguage('rig', rig)`.
- **rip print:** link the module into rip print's languages folder:

  ```sh
  mkdir -p ~/.config/rip/print/languages
  ln -s ~/Data/Code/rig/editors/highlightjs/rig.js ~/.config/rip/print/languages/rig.js
  ```

## Language server

`rig lsp` is a language server (LSP 3.17) on stdin and stdout, built into
`bin/rig`. An editor starts it and keeps it running; it gives:

- **Diagnostics.** As you type, the parse errors of the text, from Rig's
  own parser. When a file is opened and when it is saved, the
  diagnostics `rig check FILE` prints, from the same checks run in the
  server on the editor's text: types, ownership, and every other check,
  each note attached to its error as related information. A file is
  checked as the root of its program, as `rig check FILE` checks it; an
  error in a file it imports is published to that file. Between a change
  and the next save, a file shows only its parse errors.
- **Semantic tokens**, from the tokens the lexer wrapper classifies: a
  contextual word (`new`, `obj`, `unique`), a postfix `if`, or a reserved
  word used as a member name has the kind the compiler gives it. From
  the tree come the declared names (functions, objects, enums, types,
  fields, variants), parameters, labels, builtins, and the sigils, which
  the parser tells from operators by where they stand. The legend's
  types follow `@highlight`'s scopes: `keyword` (with the modifier
  `control` for `keyword.control`), `operator`, `string`, `number`,
  `comment`, `type`, `struct` (an object), `enum`, `enumMember`,
  `property` (a field), `function`, `method`, `parameter`, `label`,
  `modifier` (a sigil, `storage.modifier`), and `invalid`.
- **Document symbols**: an outline of the file's functions, objects
  with their fields and methods, enums with their variants, types,
  tests, and constants.
- **Folding ranges**: every indented block, and every run of comment
  lines.

The parse that builds the outline, the tokens' kinds, and the folds goes
on past a syntax error, so one error does not hide the rest of the file.
Positions count UTF-16 code units, or bytes when the client offers
`utf-8` in its `positionEncodings`. Hover, go to definition, completion,
rename, and formatting are not built yet (TODO.md).

The server reads `Content-Length`-framed JSON-RPC, so a client is the
easy way to drive it by hand: `test/cli/_lsp.py` is a small one, which
`test/cli/lsp.sh` uses.

### VS Code

The extension in `vscode/` starts `rig lsp` for every .rig file. The
setting `rig.lsp.path` names the `rig` executable (`rig` on `PATH` by
default). If the server cannot start, the extension says so and the
TextMate grammar still colours the file.

### Neovim

With Neovim 0.11 or later, after `vim.filetype.add({ extension = { rig =
'rig' } })` (or with `editors/vim` on the runtime path):

```lua
vim.lsp.config('rig', { cmd = { 'rig', 'lsp' }, filetypes = { 'rig' } })
vim.lsp.enable('rig')
```

On an older Neovim, start it for each Rig buffer:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'rig',
  callback = function(args)
    vim.lsp.start({ name = 'rig', cmd = { 'rig', 'lsp' }, root_dir = vim.fs.dirname(args.file) })
  end,
})
```

### Vim

With [vim-lsp](https://github.com/prabirshrestha/vim-lsp) and
`editors/vim` on the runtime path:

```vim
if executable('rig')
  autocmd User lsp_setup call lsp#register_server({
    \ 'name': 'rig',
    \ 'cmd': {server_info -> ['rig', 'lsp']},
    \ 'allowlist': ['rig'],
    \ })
endif
```
