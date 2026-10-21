# Release builds allocate from a heap per thread with no lock
# (src/alloc.zig), and a task may resume on another worker after any
# switch: each allocation must use the heap of the thread it runs on,
# which a safe build checks. Many tasks on 8 workers allocate, yield,
# and allocate again, and `main` frees what they made, on its own
# worker; built --release (Zig's safe mode, where the check is), run
# several times.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >switch.rig <<'EOF'
use std.task

fun churn(seed: Int) -> List[String]!
  out = List[String]()
  for i in 0..400
    a = String("a", i, "-", seed)
    task.check()!
    b = String(a, "/", seed)
    task.check()!
    xs = List[Int]()
    for k in 0..(i % 7)
      !xs.push(k)
    task.check()!
    !out.push(String(b, ":", xs.len))
  out

sub main()!
  total = 0
  for 0..30
    ts = Tasks[List[String]!]()
    for k in 0..32
      !ts.add(churn(k)&)
    lists = >ts!
    for l in lists
      total += l.len
  print(total)
EOF
rig build --release -o switch switch.rig >build.log 2>&1 || fail "build switch: $(cat build.log)"
for i in 1 2 3 4 5; do
    out=$(RIG_WORKERS=8 quiet ./switch 2>&1) || fail "run $i: exit $?: $out"
    expect_eq "$out" "384000" "run $i"
done
exit 0
