# A program lives in its root file's directory: every `use` names a file
# there, by its exact name. The root is emitted under a name no module
# can have, and a deep import chain loads without recursion.
source "$ROOT/test/cli/_lib.sh"

# A module reached through a symlink into another directory still imports
# from the root's directory, so two files named `c.rig` cannot meet.
mkdir -p a other
printf 'use c\nuse b\n\nsub main()\n  print(b.fromb())\n  print(c.val())\n' >a/main.rig
printf 'pub fun val() -> Int\n  1\n' >a/c.rig
printf 'use c\n\npub fun fromb() -> Int\n  c.val()\n' >other/b.rig
printf 'pub fun val() -> Int\n  20\n' >other/c.rig
ln -s ../other/b.rig a/b.rig
out=$(rig run a/main.rig 2>&1); expect_rc $? 0 "symlinked module"
expect_eq "$out" $'1\n1' "symlinked module imports from the root's directory"

# One file under two names is rejected, as is a name spelled differently
# from the file (whether or not the filesystem ignores case).
mkdir alias
printf 'pub fun val() -> Int\n  1\n' >alias/x.rig
ln -s x.rig alias/y.rig
printf 'use x\nuse y\n\nsub main()\n  print(x.val() + y.val())\n' >alias/main.rig
out=$("$RIG" check alias/main.rig 2>&1); expect_rc $? 1 "one file under two names"
expect_has "$out" "alias/main.rig:2:1: error: module \`y\` is the file \`x.rig\`; import it by that name" "one file under two names"
printf 'pub fun val() -> Int\n  1\n' >alias/util.rig
printf 'use Util\n\nsub main()\n  print(Util.val())\n' >alias/case.rig
out=$("$RIG" check alias/case.rig 2>&1); expect_rc $? 1 "module name in another case"
expect_has "$out" "alias/case.rig:1:1: error:" "module name in another case"

# A root file named like a Zig package, or with quotes in its name.
mkdir odd
printf 'test "t"\n  print(2)\n\nsub main()\n  print(1)\n' >odd/std.rig
out=$(rig run odd/std.rig 2>&1); expect_rc $? 0 "root named std"
expect_eq "$out" "1" "root named std"
cp odd/std.rig 'odd/a"b.rig'
out=$(rig test 'odd/a"b.rig' 2>&1); expect_rc $? 0 "root name with a quote"
expect_has "$out" '1 passed, 0 failed' "root name with a quote"

# Names starting with `__rig` are the compiler's.
printf 'pub fun val() -> Int\n  1\n' >odd/__rig_test.rig
printf 'use __rig_test\n\nsub main()\n  print(__rig_test.val())\n' >odd/main.rig
out=$("$RIG" check odd/main.rig 2>&1); expect_rc $? 1 "reserved module name"
expect_has "$out" "odd/main.rig:1:1: error: module names starting with \`__rig\` are reserved for the compiler" "reserved module name"

# A missing module, and a module that is a directory.
mkdir odd/dir.rig
printf 'use gone\nuse dir\n\nsub main()\n  print(1)\n' >odd/imports.rig
out=$("$RIG" check odd/imports.rig 2>&1); expect_rc $? 1 "unreadable modules"
expect_has "$out" "error: cannot read module \`gone\` (odd/gone.rig): no such file" "missing module"
expect_has "$out" "error: cannot read module \`dir\` (odd/dir.rig): it is a directory" "module that is a directory"

# `RIG_STD` names a directory to read the standard library from, in
# place of the copy embedded in the compiler.
mkdir stdlib
printf 'pub fun hello() -> Int\n  42\n' >stdlib/extra.rig
printf 'use std.extra\n\nsub main()\n  print(extra.hello())\n' >odd/usestd.rig
out=$(RIG_STD="$PWD/stdlib" rig run odd/usestd.rig 2>&1); expect_rc $? 0 "RIG_STD: $out"
expect_eq "$out" "42" "RIG_STD module"
out=$(RIG_STD="$PWD/stdlib" "$RIG" check odd/usestd.rig 2>&1); expect_rc $? 0 "RIG_STD check"
printf 'use std.math\n\nsub main()\n  print(math.abs(-1))\n' >odd/nomath.rig
out=$(RIG_STD="$PWD/stdlib" "$RIG" check odd/nomath.rig 2>&1); expect_rc $? 1 "RIG_STD without the module"
expect_has "$out" "odd/nomath.rig:1:1: error: the standard library has no module \`math\`" "RIG_STD without the module"

# A module of the standard library imports only `std.NAME`, never a
# program's file.
printf 'use helper\n\npub fun hello() -> Int\n  helper.one()\n' >stdlib/extra.rig
printf 'pub fun one() -> Int\n  1\n' >odd/helper.rig
out=$(RIG_STD="$PWD/stdlib" "$RIG" check odd/usestd.rig 2>&1); expect_rc $? 1 "std importing a program file"
expect_has "$out" "stdlib/extra.rig:1:1: error: a module of the standard library imports only other modules of it: \`use std.helper\`" "std importing a program file"

# `RIG_STD` naming the program's own directory still keeps its modules
# and the standard library's apart: `std.shim` may bind Zig code, and
# the same file imported as `shim` is the program's, which may not.
mkdir both
printf 'extern zig "shim.zig"\n  pub fun one -> Int\n' >both/shim.rig
printf 'pub fn one() i64 {\n    return 1;\n}\n' >both/shim.zig
printf 'use std.shim\n\nsub main()\n  print(shim.one())\n' >both/main.rig
out=$(RIG_STD="$PWD/both" rig run both/main.rig 2>&1); expect_rc $? 0 "std module in the program's directory: $out"
expect_eq "$out" "1" "std module in the program's directory"
printf 'use std.shim\nuse shim as mine\n\nsub main()\n  print(shim.one())\n' >both/two.rig
out=$(RIG_STD="$PWD/both" "$RIG" check both/two.rig 2>&1); expect_rc $? 1 "one file as std and as the program's"
expect_has "$out" "both/shim.rig:1:1: error: only the standard library binds declarations to Zig code" "one file as std and as the program's"

# Import mistakes: a missing `RIG_STD` directory, a module imported
# twice, and `use std` with no `std.rig`.
out=$(RIG_STD="$PWD/nowhere" "$RIG" check odd/nomath.rig 2>&1); expect_rc $? 1 "missing RIG_STD"
expect_has "$out" "odd/nomath.rig:1:1: error: RIG_STD names \`$PWD/nowhere\`, which is not a directory" "missing RIG_STD"
printf 'use std.math\nuse std.math\n\nsub main()\n  print(math.abs(-1))\n' >odd/twice.rig
out=$("$RIG" check odd/twice.rig 2>&1); expect_rc $? 1 "imported twice"
expect_has "$out" "odd/twice.rig:2:1: error: \`std.math\` is already imported as \`math\`" "imported twice"
mkdir bare
printf 'use std\n\nsub main()\n  print(1)\n' >bare/main.rig
out=$("$RIG" check bare/main.rig 2>&1); expect_rc $? 1 "bare use std"
expect_has "$out" "cannot read module \`std\` (bare/std.rig): no such file; a module of the standard library is \`use std.NAME\`" "bare use std"

# A 3000-module import chain.
mkdir chain
for ((i = 0; i < 3000; i++)); do
  if ((i < 2999)); then
    printf 'use m%d\n\npub fun f%d() -> Int\n  m%d.f%d() + 1\n' $((i + 1)) $i $((i + 1)) $((i + 1)) >chain/m$i.rig
  else
    printf 'pub fun f%d() -> Int\n  1\n' $i >chain/m$i.rig
  fi
done
printf 'use m0\n\nsub main()\n  print(m0.f0())\n' >chain/main.rig
out=$("$RIG" check chain/main.rig 2>&1); expect_rc $? 0 "deep import chain: $out"
exit 0
