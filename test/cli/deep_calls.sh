# A chain of calls as long as a program makes it is checked without the
# compiler nesting once per call: each pass that follows calls keeps a
# stack of its own (the result bounds of `proofs.Summaries`, the frames
# and expansions `inlining` finds, its search for cycles, and the
# proxies `sema.importSymbol` makes of another module's generics). Each
# chain is longer than the one that overflowed the compiler's stack.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# chain <n> <head> <step> <last> <main>: functions 0..n-1, each `head`
# with `%d` its number, whose body is `step` (`%d` the next one), and the
# last's `last`; then `main`.
chain() {
    awk -v n="$1" -v head="$2" -v step="$3" -v last="$4" -v main="$5" 'BEGIN {
        for (i = 0; i < n; i++) {
            printf head "\n  ", i
            if (i < n - 1) printf step "\n\n", i + 1; else printf last "\n\n", i
        }
        printf "%s\n", main
    }'
}

# An `Int` chain, whose result bounds the proofs find from the last one up.
chain 20000 'fun f%d(x: Int) -> Int' 'f%d(x)' 'x' 'sub main()\n  print(f0(1))' >ints.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check ints.rig 2>&1); expect_rc $? 0 "a chain of 20,000 Int calls: $out"
out=$(rig run ints.rig 2>&1); expect_rc $? 0 "run a chain of 20,000 Int calls: $out"
expect_eq "$out" 1 "a chain of 20,000 Int calls"

# A chain whose result bounds a field: a constructor at its end.
{
    printf 'obj P\n  k: Int\n\n'
    chain 100000 'fun f%d() -> P' 'f%d()' 'P(k: 3)' 'sub main()\n  xs = [1, 2, 3, 4]\n  print(xs[f0().k])'
} >fields.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check fields.rig 2>&1); expect_rc $? 0 "a chain of 100,000 calls bounding a field: $out"

# Small fallible functions the rule inlines, each into the one before.
{
    printf 'error E\n  bad\n\n'
    chain 100000 'fun f%d(x: Int) -> Int!' 'f%d(x)!' 'if x > 5\n    return E.bad\n  x' 'sub main()\n  print(f0(1) catch 0)'
} >fallible.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check fallible.rig 2>&1); expect_rc $? 0 "a chain of 100,000 inlined calls: $out"

# The search for cycles of calls walks the whole chain.
chain 300000 'sub f%d(x: Int)' 'f%d(x)' 'print(x)' 'sub main()\n  f0(1)' >subs.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check subs.rig 2>&1); expect_rc $? 0 "a chain of 300,000 calls: $out"

# Another module's generic functions, each calling the next: each one's
# type parameter is imported with the calls its body makes.
mkdir -p generic
chain 20000 'pub fun f%d[T](x: T) -> T' 'f%d(x)' 'x' '' >generic/lib.rig
printf 'use lib\n\nsub main()\n  print(lib.f0(1))\n' >generic/main.rig
out=$("$TIMEOUT_CMD" 120 "$RIG" check generic/main.rig 2>&1); expect_rc $? 0 "a chain of 20,000 generic calls in another module: $out"
