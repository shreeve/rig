# Objects nested by value, deep or wide, build and run, up to the depth
# Zig can compile: no type nests more than `sema.max_value_depth` (1000)
# levels by value, an object, enum, optional, array, or vector each a
# level, and a deeper one is rejected once, at the first type past it.
# The runtime's walks over a type (`rig.needsDrop`) take the budget an
# emitted function does, so neither a chain nor an object of many fields
# runs out of it. The chains too long for any pass to nest once per link
# are test/cli/deep_types.sh.
# timeout: 120
source "$ROOT/test/cli/_lib.sh"

# chain <n> <next> <last> <fields>: objects A0..A<n-1>, each with
# `fields` Int fields and a field of the next's type, `next` with `%d`
# its number, and the last's field `last`.
chain() {
    awk -v n="$1" -v next_="$2" -v last="$3" -v k="$4" 'BEGIN {
        for (i = 0; i < n; i++) {
            printf "obj A%d\n", i
            for (j = 0; j < k; j++) printf "  f%d: Int\n", j
            if (i < n - 1) printf "  a: " next_ "\n\n", i + 1; else printf "  %s\n\n", last
        }
    }'
}

# A hundred objects of nine fields each, an optional of the first kept in
# a List and cleared.
{
    chain 100 'A%d' 's: String' 9
    printf 'sub main()\n  x: A0? = none\n  xs: List[A0?] = List()\n  !xs.push(<x)\n  !xs.clear()\n  print(xs.len)\n'
} >nine.rig
out=$(rig run nine.rig 2>&1); expect_rc $? 0 "a chain of 100 objects of nine fields: $out"
expect_eq "$out" 0 "a chain of 100 objects of nine fields"

# One object of 1,500 fields.
{
    printf 'obj W\n'
    awk 'BEGIN { for (j = 0; j < 1500; j++) printf "  f%d: Int\n", j }'
    printf '  s: String\n\nsub main()\n  x: W? = none\n  xs: List[W?] = List()\n  !xs.push(<x)\n  !xs.clear()\n  print(xs.len)\n'
} >wide.rig
out=$(rig run wide.rig 2>&1); expect_rc $? 0 "an object of 1,500 fields: $out"
expect_eq "$out" 0 "an object of 1,500 fields"

# A chain 1000 deep, the limit: made, cloned, compared, hashed, kept in a
# List, and dropped.
{
    chain 1000 'A%d' 's: String' 1
    awk 'BEGIN {
        for (i = 0; i < 999; i++) printf "fun mk%d() -> A%d\n  A%d(f0: %d, a: mk%d())\n\n", i, i, i, i, i + 1
        printf "fun mk999() -> A999\n  A999(f0: 999, s: String(\"end\"))\n\n"
    }'
    printf 'sub main()\n  x = mk0()\n  y = +x\n  print(x == y, x.hash() == y.hash(), x.a.a.f0)\n'
    printf '  xs: List[A0?] = List()\n  !xs.push(<y)\n  z: A0? = none\n  !xs.push(<z)\n  print(xs.len)\n'
} >limit.rig
out=$(rig run limit.rig 2>&1); expect_rc $? 0 "a chain of 1,000 objects: $out"
expect_eq "$out" $'true true 2\n2' "a chain of 1,000 objects"

# One deeper is rejected, at the first object.
{
    chain 1001 'A%d' 's: String' 1
    printf 'sub main()\n  x: A0? = none\n  print(x == none)\n'
} >deeper.rig
out=$("$RIG" check deeper.rig 2>&1); expect_rc $? 1 "a chain of 1,001 objects"
expect_has "$out" 'deeper.rig:1:5: error: `A0` nests 1001 types deep by value; a value nests at most 1000 deep. Hold a part in a box (`^T`) or a `List`' "a chain of 1,001 objects"
expect_eq "$(grep -c 'error:' <<<"$out")" 1 "errors for a chain of 1,001 objects"

# An optional is a level too: 501 objects, each holding the next's
# optional, nest 1001 deep.
{
    chain 501 'A%d?' 's: String' 1
    printf 'sub main()\n  x: A0? = none\n  print(x == none)\n'
} >optional.rig
out=$("$RIG" check optional.rig 2>&1); expect_rc $? 1 "a chain of 501 objects through optionals"
expect_has "$out" 'optional.rig:1:5: error: `A0` nests 1001 types deep by value' "a chain of 501 objects through optionals"
expect_eq "$(grep -c 'error:' <<<"$out")" 1 "errors for a chain of 501 objects through optionals"

# Through a box, a chain nests no deeper than one object.
{
    chain 2000 '^A%d?' 's: String' 1
    printf 'sub main()\n  x: A0? = none\n  xs: List[A0?] = List()\n  !xs.push(<x)\n  print(xs.len)\n'
} >boxed.rig
out=$(rig run boxed.rig 2>&1); expect_rc $? 0 "a chain of 2,000 boxed objects: $out"
expect_eq "$out" 1 "a chain of 2,000 boxed objects"
