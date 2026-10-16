# A chain of types, each naming the next, as long as a program makes it
# is checked without the compiler nesting once per link: each pass that
# follows what a type holds or names keeps a stack of its own (the
# aliases `resolve` resolves, the sizes of a generic's instances, what a
# view in a signature may point into, whether `print` is handed a
# `[]U8`, and the proxies of another module's generic types). Each chain
# is longer than the one that overflowed the compiler's stack. An alias
# may not name a type nested more than `sema.max_alias_height` deep,
# which every walk over a type's structure would follow.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# decls <n> <decl> <last>: declarations 0..n-1, each `decl` with `%d`
# its number and `%d` the next one's, but the last's, `last`.
decls() {
    awk -v n="$1" -v decl="$2" -v last="$3" 'BEGIN {
        for (i = 0; i < n - 1; i++) printf decl "\n", i, i + 1
        printf last "\n", n - 1
    }'
}

# Aliases, each naming the next, resolved from the last one up.
{
    decls 20000 'type A%d = A%d' 'type A%d = Int'
    printf '\nsub main()\n  x: A0 = 3\n  print(x)\n'
} >aliases.rig
out=$(rig run aliases.rig 2>&1); expect_rc $? 0 "a chain of 20,000 aliases: $out"
expect_eq "$out" 3 "a chain of 20,000 aliases"

# A cycle of 20,000 aliases is reported once, where it is found.
{
    decls 20000 'type A%d = A%d' 'type A%d = A0'
    printf '\nsub main()\n  print(1)\n'
} >cycle.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check cycle.rig 2>&1); expect_rc $? 1 "a cycle of 20,000 aliases"
expect_has "$out" 'cycle.rig:1:6: error: type alias `A0` refers to itself' "a cycle of 20,000 aliases"
expect_eq "$(grep -c 'error:' <<<"$out")" 1 "errors for a cycle of 20,000 aliases"

# Aliases that nest a type in another: 200 deep is a type, and deeper
# is rejected at the first alias past it, whatever the constructor.
{
    decls 200 'type A%d = List[A%d]' 'type A%d = Int'
    printf '\nsub main()\n  x: A0 = List()\n  print(x.len)\n'
} >nested.rig
out=$(rig run nested.rig 2>&1); expect_rc $? 0 "aliases nesting 200 deep: $out"
expect_eq "$out" 0 "aliases nesting 200 deep"
for shape in 'List[A%d]' '[1]A%d' 'fun(A%d) -> Int' 'A%d?'; do
    {
        decls 20000 "type A%d = $shape" 'type A%d = Int'
        printf '\nsub main()\n  print(1)\n'
    } >deeper.rig
    out=$("$TIMEOUT_CMD" 120 "$RIG" check deeper.rig 2>&1); expect_rc $? 1 "aliases nesting 20,000 deep through $shape"
    expect_has "$out" 'deeper.rig:19799:6: error: type alias `A19798` names a type nested more than 200 deep' "aliases nesting 20,000 deep through $shape"
    expect_eq "$(grep -c 'error:' <<<"$out")" 1 "errors for aliases nesting 20,000 deep through $shape"
done

# A generic type, each holding the next: its instance is sized from the
# last one up.
{
    decls 20000 'obj G%d[T]\n  a: G%d[T]\n' 'obj G%d[T]\n  v: T'
    printf '\nsub main()\n  print(@size(G0[Int]) > 0)\n'
} >generic.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check generic.rig 2>&1); expect_rc $? 0 "a chain of 20,000 generic types: $out"

# A chain of 300 generic instances, made, compared, kept, and dropped.
{
    decls 300 'obj G%d[T]\n  a: G%d[T]\n' 'obj G%d[T]\n  v: T\n'
    awk 'BEGIN {
        for (i = 0; i < 299; i++) printf "fun mk%d() -> G%d[String]\n  G%d[String](a: mk%d())\n\n", i, i, i, i + 1
        printf "fun mk299() -> G299[String]\n  G299[String](v: String(\"x\"))\n\n"
    }'
    printf 'sub main()\n  x = mk0()\n  y = mk0()\n  print(x == y)\n  xs: List[G0[String]] = List()\n  !xs.push(<x)\n  print(xs.len)\n'
} >instances.rig
out=$(rig run instances.rig 2>&1); expect_rc $? 0 "a chain of 300 generic instances: $out"
expect_eq "$out" $'true\n1' "a chain of 300 generic instances"

# Types holding each other by value, in a signature: what its views may
# point into is found once per type.
{
    decls 100000 'obj A%d\n  a: A%d\n' 'obj A%d\n  s: String\n'
    printf 'fun g(a: ?A0) -> ?A1\n  ?a.a\n\nsub h(a: !A0, b: A0)\n  print(1)\n\nsub main()\n  print(1)\n'
} >signature.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check signature.rig 2>&1); expect_rc $? 0 "a chain of 100,000 types in a signature: $out"

# `print` of a value of such a type looks through it for a `[]U8`.
{
    decls 300000 'obj A%d\n  a: A%d\n' 'obj A%d\n  s: String\n'
    printf 'sub main()\n  x: A0? = none\n  print(x)\n'
} >printed.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check printed.rig 2>&1); expect_rc $? 0 "print of a chain of 300,000 types: $out"

# Another module's generic types, each holding the next: each one's proxy
# is made here.
mkdir -p module
decls 20000 'pub obj G%d[T]\n  pub a: G%d[T]\n' 'pub obj G%d[T]\n  pub v: T' >module/lib.rig
printf 'use lib\n\nsub main()\n  print(@size(lib.G0[Int]) > 0)\n' >module/main.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check module/main.rig 2>&1); expect_rc $? 0 "a chain of 20,000 generic types in another module: $out"
