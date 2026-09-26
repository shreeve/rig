# A long chain of public generics is checked for nesting itself in time
# linear in its length: 1200 functions, each calling the one before at
# its own parameter, and 400 types, each using the one before in a
# method.
source "$ROOT/test/cli/_lib.sh"

{
  printf 'pub fun f0[T](a: T, b: T) -> Int\n  1\n'
  for ((i = 1; i < 1200; i++)); do
    printf '\npub fun f%d[T](a: T, b: T) -> Int\n  f%d(a, b) + 1\n' $i $((i - 1))
  done
  printf '\npub struct S0[T]\n  v: T\n'
  for ((i = 1; i < 400; i++)); do
    printf '\npub struct S%d[T]\n  v: T\n\n  fun get(?self) -> Int\n    s: S%d[T]? = none\n    1 if s == none else 0\n' $i $((i - 1))
  done
} >lib.rig
printf 'use lib\n\nsub main()\n  s = lib.S399(v: 2)\n  print(lib.f1199(1, 2), s.get())\n' >main.rig
out=$("$TIMEOUT_CMD" 10 "$RIG" check main.rig 2>&1); expect_rc $? 0 "long chain of public generics"
