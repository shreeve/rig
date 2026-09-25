# Known bugs

Each `test/known/<area>/<name>.rig` (or `<name>/main.rig`) is a known
bug, written as a behavior or reject test of the *correct* behavior
(see [../README.md](../README.md#directives)), with a header comment
that says what goes wrong today.

`./test/run` counts a failing known test as `known`, not as a failure.
When a fix makes one pass, it reports `FIXED` and the suite fails until
the test moves to `test/behavior/` or `test/reject/`, under the same
area, in the same commit, without the note about the bug.

A bug that is fixed in the same change as its test needs no entry
here.
