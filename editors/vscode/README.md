# Rig for VS Code

Syntax highlighting for [Rig](https://github.com/shreeve/rig) (`.rig`
files): keywords, types, ownership sigils (`<x ?x !x +x ^x *x ~x`),
builtins, labels, strings with escapes, and the forms Rig rejects.

With `rig` installed, the extension also starts its language server,
`rig lsp`: the diagnostics `rig check` gives (on open and save, and
parse errors as you type), semantic highlighting as the compiler reads
the file, an outline, and folding. The setting `rig.lsp.path` names the
`rig` executable (default: `rig` on `PATH`).

The grammar and language configuration are generated from `rig.grammar`
by Nexus (`nexus --highlight all rig.grammar editors`); see
`editors/README.md` in the Rig repository.
