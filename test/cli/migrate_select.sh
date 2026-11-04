# tools/migrate-select.py rewrites a select of closure arms as one of
# named arms, and the program prints what it printed. It never changes
# what a program does: a closure that copies a capture in (`|+k, v|`)
# that another arm names may see that arm change it after the copy, so
# that select is reported (MANUAL) and left as it is.
source "$ROOT/test/cli/_lib.sh"

cat >ok.rig <<'EOF'
use std.task

fun twice(v: Int?) -> Int
  2 * (v ?? 0)

sub main()!
  a = *Chan[Int](1)
  b = *Chan[Int](1)
  !a.send(5)!
  !b.send(0)!
  k = 100
  x = task.select(
    (!a).on_recv(|+k, v| k + (v ?? 0)),
    (!b).on_send(1, || -1),
  )!
  !a.send(4)!
  y = task.select((!a).on_recv(twice), (!b).on_send(2, || -2))!
  print(x, y, (!b).recv()! ?? 0)
EOF
cat >copy.rig <<'EOF'
use std.task

fun bump(n: !Int) -> Int
  n += 1
  n

sub main()!
  a = *Chan[Int](1)
  b = *Chan[Int](1)
  !a.send(5)!
  !b.send(0)!
  k = 10
  x = task.select((!a).on_recv(|+k, v| k), (!b).on_send(<bump(!k), || -1))!
  print(x, k)
EOF
before_ok=$("$RIG" run ok.rig 2>&1) || fail "ok.rig: $before_ok"
cp copy.rig copy.orig
python3 "$ROOT/tools/migrate-select.py" ok.rig copy.rig >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "ok.rig: 2" "both selects of ok.rig rewritten"
expect_has "$(cat out.txt)" "MANUAL copy.rig:13: a closure that copies \`k\` in, which another arm names" "a copy another arm changes"
cmp -s copy.rig copy.orig || fail "copy.rig changed: $(diff copy.orig copy.rig)"
grep -q 'match task.select(' ok.rig || fail "no named select: $(cat ok.rig)"
after_ok=$("$RIG" run ok.rig 2>&1) || fail "ok.rig after: $after_ok"
expect_eq "$after_ok" "$before_ok" "ok.rig prints what it printed"
