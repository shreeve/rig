#!/usr/bin/env python3
"""The prose of the docs that the Box -> ^T rename leaves, by hand: exact
replacements, each of which must match once."""
import sys
EDITS = [
("HANDOFF.md", "one lend table serves every owner (Vec, Text, Box, `*T`,", "one lend table serves every owner (Vec, Text, `^T`, `*T`,"),
("HANDOFF.md", "and `+x` deep-copies Vec, Box,", "and `+x` deep-copies Vec, `^T`,"),
("HANDOFF.md", "owners behind `Cell`, `Box`, and", "owners behind `Cell`, `^T`, and"),
("README.md", "handles, `Cell`, `Vec`, `Box`, and `Signal`", "handles, `Cell`, `Vec`, `^T`, and `Signal`"),
("SPEC.md", "takes `?s` of a `Shape`, a `Box[Shape]`, and a", "takes `?s` of a `Shape`, a `^Shape`, and a"),
("SPEC.md", "value shares storage the place owns: a Vec, a `Box`, a `*T` or `~T`", "value shares storage the place owns: a Vec, a `^T`, a `*T` or `~T`"),
("SPEC.md", "through a view, a `*T` handle, a `Box`, or", "through a view, a `*T` handle, a `^T`, or"),
("SPEC.md", "| `Box` | the value it holds |", "| `^T` | the value it holds |"),
("SYNTAX.md", "The built-in types `Cell`, `Vec`, `Box`, `Text`, `Signal`, and\n`Endian` are reserved names.", "The built-in types `Cell`, `Vec`, `Text`, `Signal`, and\n`Endian` are reserved names."),
("WELCOME.md", "beyond `print`, `Cell`, `Vec`, `Box`,", "beyond `print`, `Cell`, `Vec`,"),
("docs/CORE.md", "a `match` on a `Box`)", "a `match` on a `^T`)"),
("docs/DESIGN.md", "the allocation a `Vec`, `Box`, or `Text` makes", "the allocation a `Vec`, `^T`, or `Text` makes"),
("docs/INTERNALS.md", "`Cell`, `Vec`, `Box`, `Signal` as built-in generics", "`Cell`, `Vec`, `Signal` as built-in generics, `^T` as a built-in generic that no name reaches"),
("docs/INTERNALS.md", "holds a `*T`, `~T`, Vec, Box, Text, or owned closure", "holds a `*T`, `~T`, Vec, `^T`, Text, or owned closure"),
("docs/INTERNALS.md", "(not behind a handle, a view, or a Vec's or Box's buffer)", "(not behind a handle, a view, or a Vec's or box's buffer)"),
("docs/INTERNALS.md", "length, and a `Box` its pointer.", "length, and a `^T` its pointer."),
("docs/INTERNALS.md", "handles, and a Vec's or Box's elements,", "handles, and a Vec's or box's elements,"),
("docs/INTERNALS.md", "`Box`, and every argument of a generic instance)", "`^T`, and every argument of a generic instance)"),
("docs/INTERNALS.md", "**A holder of a read view.** A `Box`, an optional,", "**A holder of a read view.** A `^T`, an optional,"),
("docs/INTERNALS.md", "array's, Vec's, Box's, Cell's or Signal's", "array's, Vec's, box's, Cell's or Signal's"),
("docs/INTERNALS.md", "| `^T` | `^T`: a pointer to one heap `T`.", "| `Box(T)` | `^T`: a pointer to one heap `T`."),
]
if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    for f, a, b in EDITS:
        s = open(root + "/" + f).read()
        if s.count(a) != 1:
            print("NOT ONCE (%d): %s: %s" % (s.count(a), f, a))
            continue
        open(root + "/" + f, "w").write(s.replace(a, b))
