# A payload part a `match <e` arm leaves unused is dropped at each exit
# of the arm, by address (`rig.discardAt`). Dropped by value, each of
# this arm's 12,000 exits held a copy of the 4 MB part: a 48 GB frame,
# which made Zig's aarch64 build fail with `fixup value out of range`.
# The program is written here, not kept in test/corpus/, since the
# reference checker takes memory quadratic in an arm's exits (TODO.md).
source "$ROOT/test/cli/_lib.sh"

python3 - >build.rig <<'PY'
print('''obj H
  s: String
  a: [500000]Int

enum E
  one(h: H, n: Int)
  two

fun mk(k: Int) -> E
  E.one(h: H(s: String("x"), a: [500000 of k]), n: 5)

fun arm(e: E, i: Int) -> Int
  match <e
    .one(_, n)''')
for k in range(12000):
    print(f'      return {k} if i == {100 + k}')
print('''      n
    .two => 0

sub main()
  print("before")
  print(arm(mk(1), 1))''')
PY
out=$(rig run build.rig 2>&1) || fail "an arm with 12,000 exits: $out"
expect_eq "$out" $'before\n5' "an arm with 12,000 exits"
exit 0
