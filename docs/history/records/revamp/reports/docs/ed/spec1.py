E = []
E.append((r'''This is the reference for Rig as the compiler implements it today. Every
rule here is enforced by `rig check`, and every example is run by
`./test/run`: a program followed by an `output` block must print exactly
that output with no leaks, and a program marked as rejected must fail
with the error shown. For the reasons behind the rules, see
[docs/DESIGN.md](docs/DESIGN.md); for what is not built yet, see
[docs/ROADMAP.md](docs/ROADMAP.md).

```rig
sub main
  print("hello, rig")
```

```output
hello, rig
```

## Contents

1. [Programs](#1-programs)
2. [Lexical structure](#2-lexical-structure)
3. [Types](#3-types)''', r'''This is the reference for Rig as the compiler implements it today: what
each form means, and the rules `rig check` enforces. How each form is
written (layout, names, literals, operators and their precedence, and
the grammar) is in [SYNTAX.md](SYNTAX.md), and a guided start from
another language is [WELCOME.md](WELCOME.md). For the reasons behind
the rules, see [docs/DESIGN.md](docs/DESIGN.md); for what is not built
yet, see [docs/ROADMAP.md](docs/ROADMAP.md).

Every example is run by `./test/run`: a program followed by an `output`
block must print exactly that output with no leaks, and a program
marked as rejected must fail with the errors shown.

## Contents

1. [Programs](#1-programs)
3. [Types](#3-types)'''))

E.append((r'''A Rig program is a file of declarations: functions (`fun`, `sub`),
types (`struct`, `enum`, `error`, `type`), constants (`name = value`),
imports (`use`), `extern` declarations, and `test` blocks. Statements
live inside functions. The file's name ends in `.rig`, and a program
that runs declares its entry point as `sub main`, with no parameters.
Only the program calls it: Rig code cannot call `main` or use it as a
value.
`rig check` checks''', r'''A Rig program is a file of declarations: functions (`fun`, `sub`),
types (`struct`, `enum`, `error`, `type`), constants (`name = value`),
imports (`use`), `extern` declarations, and `test` blocks, written as
[SYNTAX.md](SYNTAX.md) shows. Statements live inside functions. A
program that runs declares its entry point as `sub main`, with no
parameters. Only the program calls it: Rig code cannot call `main` or
use it as a value.

`rig check` checks'''))

# drop the whole lexical section: from '## 2. Lexical structure' up to '## 3. Types'
