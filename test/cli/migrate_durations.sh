# tools/migrate-durations.py rewrites a 0.3.0 program's durations, bare
# nanoseconds, in the forms of 0.3.1, where a bare number is seconds, and
# the program means what it meant: each Instant below is the nanoseconds
# 0.3.0 gave it. A `per:` it cannot count in seconds is reported
# (MANUAL), and a Markdown file's ```rig blocks are rewritten, not its
# prose.
source "$ROOT/test/cli/_lib.sh"

cat >old.rig <<'EOF'
use std.task
use std.time

fun work() -> Int!
  time.sleep(time.MS)!
  7

sub main()!
  z = time.Instant.at(0)
  d = 7
  print(z.add(40 * time.MS).since(z), z.add(5 * time.US).since(z), z.add(2 * time.SECOND).since(z), z.add(time.MS).since(z))
  print(time.Instant.at(1_000_000).since(z), time.Instant.at(d).since(z), time.Instant.at(3 * time.MINUTE).since(z), time.Instant.at((d % 4) * time.US).since(z))
  time.sleep(2 * time.MS)!
  r = time.within(50 * time.MS, work)!
  s = time.within[Int](time.SECOND, || 8)!
  ch = *Chan[Int](1)
  v = match task.select(got: !ch.on_recv(), late: time.after(d))!
    .got(x) => x ?? 0
    .late => -1
  n = 3
  print(r, s, v, task.supervise(|| 9, restarts: 1, per: 1000) catch 0, task.supervise(|| 9, per: n) catch 0)
EOF
cat >new.rig <<'EOF'
use std.task
use std.time

fun work() -> Int!
  time.sleep(ms: 1)!
  7

sub main()!
  z = time.Instant.at(0)
  d = 7
  print(z.add(ms: 40).since(z), z.add(us: 5).since(z), z.add(2).since(z), z.add(ms: 1).since(z))
  print(time.Instant.at(ms: 1).since(z), time.Instant.at(ns: d).since(z), time.Instant.at(180).since(z), time.Instant.at(us: d % 4).since(z))
  time.sleep(ms: 2)!
  r = time.within(ms: 50, f: work)!
  s = time.within[Int](1, || 8)!
  ch = *Chan[Int](1)
  v = match task.select(got: !ch.on_recv(), late: time.after(ns: d))!
    .got(x) => x ?? 0
    .late => -1
  n = 3
  print(r, s, v, task.supervise(|| 9, restarts: 1, per: 0.000001) catch 0, task.supervise(|| 9, per: n) catch 0)
EOF
cat >doc.md <<'EOF'
In 0.3.0 `time.sleep(5 * time.MS)` slept five milliseconds.

```rig
use std.time

sub main()!
  time.sleep(5 * time.MS)!
```
EOF
python3 "$ROOT/tools/migrate-durations.py" old.rig doc.md >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "old.rig: 14" "every duration of old.rig rewritten"
expect_has "$(cat out.txt)" "MANUAL old.rig:21: \`per: n\` is nanoseconds" "a per: it cannot count"
expect_has "$(cat out.txt)" "CHECK old.rig:11: \`.add(40 * time.MS)\` taken as an Instant's" "an add it takes for an Instant's"
diff old.rig new.rig >diff.txt || fail "old.rig migrated differs: $(cat diff.txt)"
expect_has "$(head -1 doc.md)" "time.sleep(5 * time.MS)" "prose left as it is"
grep -q '^  time.sleep(ms: 5)!$' doc.md || fail "the rig block not rewritten: $(cat doc.md)"
out=$("$RIG" run old.rig 2>&1) || fail "old.rig after: $out"
expect_eq "$out" "40000000 5000 2000000000 1000000
1000000 7 180000000000 3000
7 8 -1 9 9" "old.rig means what it meant"
