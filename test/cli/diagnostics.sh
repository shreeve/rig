# A diagnostic is `file:line:col: error: message` at the start of the
# node it is about (keywords and sigils included), then the source line
# with the node's span underlined on it. Sema's diagnostics come before
# the ownership checker's.
source "$ROOT/test/cli/_lib.sh"

cat >spans.rig <<'EOF'
fun pick(n: Int) -> Int
  if n > 0
    return
  n

sub main()
  f = ||
    break
  x = *(*(1))
  print(pick(1), x)
  f()
EOF
"$RIG" check spans.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a rejected program"
expect_eq "$(cat out.txt)" "spans.rig:3:5: error: \`return\` needs a value of type \`Int\`
    return
    ^~~~~~
spans.rig:9:9: error: this value is already a shared handle \`*Int\`; \`*\` would nest handles. Clone it with \`+x\` for another handle
  x = *(*(1))
        ^~~~
spans.rig:8:5: error: \`break\` is not inside a loop (a closure body cannot leave a loop around it)
    break
    ^~~~~" "diagnostics at node spans"

# A parse error points at the token the parser stopped on, and says
# what the parser expected there when that is a short list.
cat >parse.rig <<'EOF'
sub main()
  x = (1 + )
EOF
"$RIG" check parse.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program that does not parse"
expect_eq "$(cat out.txt)" "parse.rig:2:12: error: unexpected \`)\`; expected an operand
  x = (1 + )
           ^" "parse error at its token"

# At most 100 errors print; the rest are counted.
{ echo "sub main()"; for ((i = 0; i < 150; i++)); do echo "  print(missing$i)"; done; } >many.rig
"$RIG" check many.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program with many errors"
expect_eq "$(grep -c ': error: ' out.txt)" "100" "errors printed"
expect_eq "$(tail -1 out.txt)" "50 more errors not shown" "errors counted"

# A column counts characters, not bytes.
printf 'sub main()\n  print("\xc3\xa9\xc3\xa9", missing)\n' >utf8.rig
"$RIG" check utf8.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program with UTF-8"
expect_eq "$(cat out.txt)" "utf8.rig:2:15: error: use of unbound name \`missing\`
  print(\"éé\", missing)
              ^~~~~~~" "UTF-8 column and caret"

# A name whose type did not resolve is reported once: calling it adds
# nothing.
printf 'extern f: Nope\n\nsub main()\n  raw\n    f(1)\n' >poison.rig
"$RIG" check poison.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a call to a poisoned name"
expect_eq "$(grep ': error: ' out.txt)" "poison.rig:1:11: error: use of unbound type \`Nope\`" "one error"

# A type parameter left unbound because an argument or the expected
# type already has an error is not reported again: only the cause is.
cat >poison.rig <<'EOF2'
fun empty[T] -> Vec[T]
  Vec()

fun id[T](a: T) -> T
  a

sub main
  z: Vec[Foo] = empty()
  x = id(id(id(empty())))
  print(z.len, x.len)
EOF2
"$RIG" check poison.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a poisoned inference"
expect_eq "$(grep 'error:' out.txt)" "poison.rig:8:10: error: use of unbound type \`Foo\`
poison.rig:9:16: error: cannot infer \`T\` for \`empty\` from its arguments or the type expected of its result; give \`T\` in brackets: \`empty[...]()\`" "only the cause of a poisoned inference"

# An instance of another module's generic is reported where it is made,
# with a note at the operation in the other module's file.
cat >lib.rig <<'EOF2'
pub fun max[T](a: T, b: T) -> T
  a if a > b else b
EOF2
cat >main.rig <<'EOF2'
use lib

struct P
  x: Int

sub main()
  print(lib.max(P(x: 1), P(x: 2)).x)
EOF2
"$RIG" check main.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a foreign instance that fails a requirement"
expect_eq "$(cat out.txt)" "main.rig:7:13: error: \`lib.max[P]\` cannot use \`T = P\`: the generic body applies \`>\` to \`T\`, which \`P\` does not support
  print(lib.max(P(x: 1), P(x: 2)).x)
            ^
lib.rig:2:8:   note: \`>\` used on \`T\` here (ordering comparison)
  a if a > b else b
       ^" "a note in another module's file"

# Each note in another module's file names that file: a requirement
# reached through a chain (in `util.rig`), a copy, an array length, an
# array made, and a generic type's declaration.
m="$ROOT/test/reject/modules"
out=$("$RIG" check "$m/foreign_chain_requirement/main.rig" 2>&1)
expect_has "$out" "$m/foreign_chain_requirement/util.rig:2:3:   note: \`+\` used on \`T\` here" "a note through a chain names its file"
out=$("$RIG" check "$m/foreign_instance_ownership/main.rig" 2>&1)
expect_has "$out" "$m/foreign_instance_ownership/lib.rig:2:7:   note: \`T\` copied here" "a copy note names its file"
out=$("$RIG" check "$m/foreign_array_len/main.rig" 2>&1)
expect_has "$out" "$m/foreign_array_len/lib.rig:12:11:   note: \`n\` used as an array length here" "an array length note names its file"
expect_has "$out" "$m/foreign_array_len/lib.rig:1:26:   note: the array is made here" "an array note names its file"
printf 'pub struct Wrap[T]\n  v: T\n' >lib.rig
printf 'use lib\n\nsub main()\n  print(lib.Wrap[Int].nope())\n' >main.rig
out=$("$RIG" check main.rig 2>&1); expect_rc $? 1 "rig check of a missing method of another module's generic"
expect_has "$out" "lib.rig:1:12:   note: \`lib.Wrap\` declared here" "a declaration note names its file"
