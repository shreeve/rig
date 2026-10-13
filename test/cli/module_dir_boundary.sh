# Each file of a directory module closes its own blocks and brackets: an
# unclosed bracket is reported in its file, and the next file is not read
# as its continuation. Diagnostics name the file they are in.
source "$ROOT/test/cli/_lib.sh"

mkdir -p p/m
printf 'use m\n\nsub main()\n  print(m.b())\n' >p/main.rig
printf 'pub fun a() -> Int\n  print((\n' >p/m/a.rig
printf 'pub fun b() -> Int\n  2\n' >p/m/b.rig
out=$("$RIG" check p/main.rig 2>&1); expect_rc $? 1 "unclosed bracket"
expect_has "$out" "p/m/a.rig:" "unclosed bracket reported in its file"
grep -q "m/b.rig" <<<"$out" && fail "unclosed bracket: nothing is reported in m/b.rig: $out"

# A block left open at the end of one file ends there: the next file's
# first declaration is a declaration of the module.
printf 'pub fun a() -> Int\n  1\n' >p/m/a.rig
printf 'pub fun b() -> Int\n  x = 2\n  y = 3\n  x + y + c()\n' >p/m/b.rig
printf 'fun c() -> Int\n  a()\n' >p/m/c.rig
out=$(rig run p/main.rig 2>&1); expect_rc $? 0 "files close their blocks: $out"
expect_eq "$out" "6" "files close their blocks"

# A file's first line may not be indented to continue the file before it.
printf '  fun d() -> Int\n    1\n' >p/m/d.rig
out=$("$RIG" check p/main.rig 2>&1); expect_rc $? 1 "indented first line"
expect_has "$out" "p/m/d.rig:1:3: error: unexpected indentation" "indented first line"
rm p/m/d.rig

# An error is reported at its file's own line and column.
printf 'fun c() -> Int\n  a() + nope\n' >p/m/c.rig
out=$("$RIG" check p/main.rig 2>&1); expect_rc $? 1 "error in a later file"
expect_has "$out" "p/m/c.rig:2:9: error:" "error position in its own file"

# A file that ends in a line continuation, or with no newline, ends its
# last line there; the next file is still read.
mkdir -p r/m
printf 'use m\n\nsub main()\n  print(m.a())\n' >r/main.rig
printf 'pub fun a() -> Int\n  1 \\' >r/m/a.rig
printf 'fun b() -> Int\n  nope\n' >r/m/b.rig
out=$("$RIG" check r/main.rig 2>&1); expect_rc $? 1 "a file ending in a continuation"
expect_has "$out" "r/m/b.rig:2:3: error: use of unbound name \`nope\`" "the file after a continuation is read"
printf 'fun b() -> Int\n  2\n' >r/m/b.rig
out=$(rig run r/main.rig 2>&1); expect_rc $? 0 "a file ending in a continuation: $out"
expect_eq "$out" "1" "a file ending in a continuation"

# A file with no tokens (empty, or only comments) is part of the module.
: >r/m/0.rig
printf '# The module m.\n' >r/m/00.rig
out=$(rig run r/main.rig 2>&1); expect_rc $? 0 "files with no tokens: $out"
expect_eq "$out" "1" "files with no tokens"

# A local may have the name another file's `use` binds.
printf 'use std.math\n\nfun c() -> Int\n  math.abs(-1)\n' >r/m/c.rig
printf 'pub fun a() -> Int\n  math = 1\n  math\n' >r/m/a.rig
out=$(rig run r/main.rig 2>&1); expect_rc $? 0 "a local named like a later use: $out"
expect_eq "$out" "1" "a local named like a later use"

# A `use` binds its name in its own file only, in a build with
# `--release` too: another file's parameters and locals may have it.
cp -R "$ROOT/test/behavior/modules/use_names_per_file" names
out=$(rig run --release names/main.rig 2>&1); expect_rc $? 0 "per-file use names with --release: $out"
expect_eq "$out" "33 2 41" "per-file use names with --release"

# `a/b.rig` is part of module `a`, and the directory `a/b/` is module
# `a.b`: both may exist.
mkdir -p s/a/b
printf 'use a\nuse a.b\n\nsub main()\n  print(a.one(), b.two())\n' >s/main.rig
printf 'pub fun one() -> Int\n  1\n' >s/a/b.rig
printf 'pub fun two() -> Int\n  2\n' >s/a/b/two.rig
out=$(rig run s/main.rig 2>&1); expect_rc $? 0 "a file and a directory of one name: $out"
expect_eq "$out" "1 2" "a file and a directory of one name"

# The module emits one Zig file, named by its path.
mkdir -p q/a/b
printf 'use a.b\n\nsub main()\n  print(b.one())\n' >q/main.rig
printf 'pub fun one() -> Int\n  1\n' >q/a/b/one.rig
out=$(rig run q/main.rig 2>&1); expect_rc $? 0 "nested module: $out"
expect_eq "$out" "1" "nested module"
RIG_OUT_DIR="$PWD/qout" "$RIG" emit q/main.rig >/dev/null 2>&1 || fail "nested module: rig emit"
[[ -f qout/a.b.zig ]] || fail "nested module emits a.b.zig: $(ls qout)"

# An empty directory is no module.
mkdir -p q/e
printf 'use e\n\nsub main()\n  print(1)\n' >q/empty.rig
out=$("$RIG" check q/empty.rig 2>&1); expect_rc $? 1 "empty directory"
expect_has "$out" "q/empty.rig:1:1: error:" "empty directory"
