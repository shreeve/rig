# tools/migrate-0.3.py reports, and never rewrites, a binding with no
# type of a loop's value that is a write view at every `break`: 0.2.9
# copied the value, and 0.3 holds the view, so the program compiles
# under both and assigning the binding now writes through. A write view
# is a lend of a path (`!x`, `!x.f`, `!x[i]`) or a call of a function
# the program, or a module it uses, declares returning `!T`. The near
# misses: a loop with a `break` of a value, a typed binding, a `for`
# whose `else` gives a value, and a call of a function returning a
# value; a nested loop's `break` of a value is its own.
source "$ROOT/test/cli/_lib.sh"

mkdir -p tree/hit tree/used/lib tree/miss
cat >tree/hit/hit.rig <<'EOF'
fun slot(a: !Int) -> !Int
  a

sub main()
  n = 12
  m = 0
  l = while true
    break slot(!n)
  l = 1
  k = for i in 0..3
    break !m if i == 1
  else
    !m
  k += 1
  o = while true
    j = for i in 0..2
      break 5 if i == 1
    else
      6
    break !n if j > 0
  o = 3
  print(n, m)
EOF
cat >tree/used/lib/lib.rig <<'EOF'
pub fun slot(a: !Int) -> !Int
  a
EOF
cat >tree/used/main.rig <<'EOF'
use lib

sub main()
  n = 1
  w = while true
    break lib.slot(!n)
  w = 2
  print(n)
EOF
cat >tree/miss/miss.rig <<'EOF'
fun slot(a: !Int) -> !Int
  a

fun val(a: !Int) -> Int
  a + 1

sub main()
  n = 12
  c = n > 5
  # a `break` of a value: the loop's value is copied
  a = while true
    break slot(!n) if c
    break 0
  # a typed binding copies
  t: Int = while true
    break slot(!n)
  # an `else` that gives a value
  k = for i in 0..3
    break slot(!n) if i == 1
  else
    0
  # a call of a function returning a value
  v = while true
    break val(!n)
  print(a, t, k, v)
EOF
for f in tree/hit/hit.rig tree/used/main.rig tree/miss/miss.rig; do
    (cd "$(dirname "$f")" && "$RIG" check "$(basename "$f")") >err.txt 2>&1 || fail "$f: $(cat err.txt)"
done
cp -R tree before

python3 "$ROOT/tools/migrate-0.3.py" scan tree >out.txt 2>&1 || fail "scan: $(cat out.txt)"
expect_has "$(cat out.txt)" "MANUAL hit/hit.rig:7: \`l = while\` holds the write view every \`break\` hands over, where 0.2.9 copied the value: write \`l: T = while\`, T the value's type, to copy as 0.2.9 did, or keep the view, through which assigning \`l\` writes" "a call's write view"
expect_has "$(cat out.txt)" "MANUAL hit/hit.rig:10: \`k = for\`" "a lend at every break and the else"
expect_has "$(cat out.txt)" "MANUAL hit/hit.rig:15: \`o = while\`" "a nested loop's break is its own"
expect_has "$(cat out.txt)" "MANUAL used/main.rig:5: \`w = while\`" "a function of a module used"
(( $(grep -c MANUAL out.txt) == 4 )) || fail "MANUAL for the hits only: $(cat out.txt)"

python3 "$ROOT/tools/migrate-0.3.py" apply tree >out.txt 2>&1 || fail "apply: $(cat out.txt)"
(( $(grep -c MANUAL out.txt) == 4 )) || fail "apply reports the hits: $(cat out.txt)"
diff -r -x .rig-migrated-0.3 tree before >/dev/null || fail "a site was rewritten: $(diff -r tree before)"
