# Each file of a directory module closes its own blocks and brackets: an
# unclosed bracket is reported in its file, and the next file is not read
# as its continuation. Diagnostics name the file they are in. The cases
# `dir boundary ...` of test/rig/modules-dir-boundary.rig.test check what
# a program shows; this checks the layouts a case cannot write: a file
# with no newline at its end, an empty file, the Zig file the module
# emits, and an empty directory.
source "$ROOT/test/cli/_lib.sh"

# A file that ends in a line continuation, with no newline, ends its last
# line there; the next file is still read. A file with no tokens (empty,
# or only comments) is part of the module.
mkdir -p r/m
printf 'use m\n\nsub main()\n  print(m.a())\n' >r/main.rig
printf 'pub fun a() -> Int\n  1 \\' >r/m/a.rig
printf 'fun b() -> Int\n  nope\n' >r/m/b.rig
out=$("$RIG" check r/main.rig 2>&1); expect_rc $? 1 "a file ending in a continuation"
expect_has "$out" "r/m/b.rig:2:3: error: use of unbound name \`nope\`" "the file after a continuation is read"
printf 'fun b() -> Int\n  2\n' >r/m/b.rig
: >r/m/0.rig
printf '# The module m.\n' >r/m/00.rig
out=$(rig run r/main.rig 2>&1); expect_rc $? 0 "a file ending in a continuation, and files with no tokens: $out"
expect_eq "$out" "1" "a file ending in a continuation, and files with no tokens"

# The module emits one Zig file, named by its path.
mkdir -p q/a/b
printf 'use a.b\n\nsub main()\n  print(b.one())\n' >q/main.rig
printf 'pub fun one() -> Int\n  1\n' >q/a/b/one.rig
RIG_OUT_DIR="$PWD/qout" "$RIG" emit q/main.rig >/dev/null 2>&1 || fail "nested module: rig emit"
[[ -f qout/a.b.zig ]] || fail "nested module emits a.b.zig: $(ls qout)"

# An empty directory is no module.
mkdir -p q/e
printf 'use e\n\nsub main()\n  print(1)\n' >q/empty.rig
out=$("$RIG" check q/empty.rig 2>&1); expect_rc $? 1 "empty directory"
expect_has "$out" "q/empty.rig:1:1: error:" "empty directory"
