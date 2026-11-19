# A fork's record in its maker's frame: the lifetime order of its Lean
# model (formal/Models/FrameRecord.lean, the `fixed` order) and its Zig
# code (src/tasks.zig) in step, then the race the order closes, run on
# real workers. A change to either side fails here until the other
# follows.
#
# The order: whoever runs the fork leaves a frame record on its
# isolate's list, and its last access is `Done`'s `ended`; whoever reads
# `ended` takes the record off under the isolate's lock: the maker at
# its join (`Control.leave`, the model's maker steps 4 and 5), or the
# isolate's stopper once the maker panicked (`Isolate.stop`,
# `takeEndedFrames`, the stopper's step 1).
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

zig="$ROOT/src/tasks.zig"
lean="$ROOT/formal/Models/FrameRecord.lean"
[[ -f $zig && -f $lean ]] || fail "missing $zig or $lean"

# zbody <file> <start-regex>: the lines from the first match to the
# closing brace at the same indent.
zbody() { awk -v re="$2" '
    !on && $0 ~ re { on = 1; match($0, /^ */); ind = RLENGTH; print; next }
    on { print; match($0, /^ */); if (RLENGTH == ind && substr($0, ind + 1, 1) == "}") exit }' "$1"; }

need() {
    local what=$1 text=$2; shift 2
    [[ -n $text ]] || fail "$what: not found"
    local s
    for s in "$@"; do grep -qF -- "$s" <<<"$text" || fail "$what: lacks [$s]"; done
}
lacks() {
    local what=$1 text=$2; shift 2
    local s
    for s in "$@"; do ! grep -qF -- "$s" <<<"$text" || fail "$what: has [$s]"; done
}

# The model: the thief's accesses in the `fixed` order end with `ended`
# and include no remove; the maker reads `ended`, then removes (5); the
# stopper removes a listed record only once it has ended.
need "FrameRecord.lean acts" "$(grep -F '| .fixed =>' "$lean")" "[.done, .wakeup, .endStack, .ending, .ended]"
need "FrameRecord.lean maker" "$(grep -F '| 4 =>' "$lean")" "if c.order == .fixed then 5 else 6"
need "FrameRecord.lean stopper" "$(grep -F 'if c.order == .fixed && s.listed && s.ended then' "$lean")" "s.listed && s.ended"

# The Zig: the thief's `finish` of a frame record touches no isolate.
fin=$(zbody "$zig" '^    fn finish[(]self: [*]Control[)]')
frame_part=$(awk '/if \(self.in_frame\) \{/ { on = 1; next } on && /\} else \{/ { exit } on { print }' <<<"$fin")
need "Control.finish of a frame record" "$frame_part" "self.done.store(true, .seq_cst);"
lacks "Control.finish of a frame record" "$frame_part" "remove" "isolate" "unlink"
# The reader of `ended` takes it off under the lock, unless the stopper did.
need "Control.leave" "$(zbody "$zig" '^    noinline fn leave[(]self: [*]Control, iso: [*]Isolate[)]')" "iso.lock.lock();" "if (self.iso_prev == null and iso.first != self) return;" "iso.unlink(self);"
need "Task.release" "$(zbody "$zig" '^        inline fn release[(]self: Self[)]')" "if (self.control.in_frame) {" "self.control.leave(iso);"
need "Isolate.stop" "$(zbody "$zig" '^    fn stop[(]self: [*]Isolate, wait: bool[)]')" "self.takeEndedFrames();" "self.lock.lock();"
need "Isolate.takeEndedFrames" "$(zbody "$zig" '^    fn takeEndedFrames[(]')" "if (!x.in_frame) continue;" "if (x.frameEnded()) self.unlink(x)"

# The race on real workers, sanitized, so a write into a stack given
# back faults: a maker under an isolate panics while its fork runs on,
# and the caller starts tasks that take stacks at once. Then fork-join
# trees on one worker and on all.
cat >race.rig <<'EOF'
use std.task

fun pick(xs: [3]Int, i: Int) -> Int
  xs[i]

fun spin(n: Int) -> Int
  s = 0
  for i in 0..n
    s += i % 3
  s

fun maker(n: Int) -> Int
  t = spin(n)&
  x = pick([1, 2, 3], 9)
  x + >t

fun outer(n: Int) -> Int
  t = maker(n)&
  >t

fun after() -> Int
  a = spin(10)&
  b = spin(10)&
  c = spin(10)&
  >a + >b + >c

fun psum(xs: ?[]Int) -> Int
  return xs.sum() if xs.len <= 64
  mid = xs.len / 2
  right = xs[mid..]
  b = psum(?right)&
  a = psum(xs[..mid])
  a + >b

sub main()
  bad = 0
  for k in 0..200
    r = task.isolate(|+k| outer(k * 37 % 3000)) catch -9
    bad += 1 if r != -9 or after() != 27
  xs: List[Int] = List()
  for i in 0..65536
    !xs.push(i)
  whole = ?xs[..]
  print(bad, psum(whole))
EOF
RIG_SANITIZE=1 rig build -o race race.rig >build.log 2>&1 || fail "build race.rig: $(tail -20 build.log)"
for w in 1 4; do
    out=$(RIG_WORKERS=$w quiet ./race 2>err.txt) || fail "race on $w workers: exit $?: $(grep -v '^panic\|^ \|^/\|^$' err.txt | head -5)"
    expect_eq "$out" "0 2147450880" "race on $w workers"
done
exit 0
