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

## Install

- **VS Code:** `cd editors/vscode && npx @vscode/vsce package`, then
  `code --install-extension vscode-rig-*.vsix`. For development, symlink
  the folder into `~/.vscode/extensions/rig-lang.vscode-rig`.
- **Vim:** add `editors/vim` to the runtime path, e.g. with vim-plug:
  `Plug '~/Data/Code/rig', { 'rtp': 'editors/vim' }`, or
  `set runtimepath+=~/Data/Code/rig/editors/vim`.
- **highlight.js:** `import rig from './editors/highlightjs/rig.js'`, then
  `hljs.registerLanguage('rig', rig)`.
