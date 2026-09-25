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
out=$("$RIG" run a/main.rig 2>&1); expect_rc $? 0 "symlinked module"
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
out=$("$RIG" run odd/std.rig 2>&1); expect_rc $? 0 "root named std"
expect_eq "$out" "1" "root named std"
cp odd/std.rig 'odd/a"b.rig'
out=$("$RIG" test 'odd/a"b.rig' 2>&1); expect_rc $? 0 "root name with a quote"
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
