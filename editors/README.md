# Editor support for Rig

Syntax highlighting for Rig in VS Code, Vim, and highlight.js. The
grammars are generated from `rig.grammar` by Nexus (`nexus --highlight`),
from its `@highlight` section; don't edit a generated file by hand. Each
starts with a header naming the grammar it came from.

| Directory | What it is |
|---|---|
| `vscode/` | A VS Code extension: `syntaxes/rig.tmLanguage.json` and `language-configuration.json` (generated), `package.json` |
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
   `"version"` in `editors/vscode/package.json` first:

   ```sh
   cd editors/vscode && npx -y @vscode/vsce package --skip-license
   ```

4. Install it, then run **Developer: Reload Window** in VS Code:

   ```sh
   code --install-extension editors/vscode/vscode-rig-0.1.0.vsix --force
   ```

The `.vsix` is not committed (`editors/vscode/.gitignore`); rebuild it
from the folder any time.

## Install

- **VS Code:** steps 3 and 4 above. While working on the grammar, a
  symlink is quicker: `ln -s "$PWD/editors/vscode"
  ~/.vscode/extensions/rig-lang.vscode-rig-0.1.0`, then reload the window
  after each regeneration. Use one or the other, not both.
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
