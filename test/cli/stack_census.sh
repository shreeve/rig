# timeout: 300
# tools/stack-census.py, the fail-closed bound of each task's stack read
# from the executable (docs/history/records/2026-11/task-memory/census.md).
# On a release build of a small program: a task of direct calls is
# bounded, with its code in the preempted section (`__rig_text` on
# macOS, which carries no instruction attributes, and `rig_text` on
# Linux); a `par.map` task, which runs its closure through a `FnRef`, is
# bounded by the thunks of that FnRef's type, and only while Rig's
# runtime holds the fact the resolution rests on, so a runtime that sets
# `call_fn` anywhere else, or one the tool cannot read, leaves it
# unknown; a recursive task stays unknown, on a cycle of calls. Then the
# rules on instructions, each on code made up for it: a spill to the
# stack is forgotten when a store or a call may have written it, and
# `clone`'s child branch is left out only in the shape of Zig's `clone`.
source "$ROOT/test/cli/_lib.sh"

objdump_ok=0
for t in llvm-objdump llvm-objdump-22; do command -v $t >/dev/null && objdump_ok=1; done
objdump --version 2>/dev/null | grep -q LLVM && objdump_ok=1
if (( ! objdump_ok )); then
    echo "skipped: needs llvm-objdump"
    exit 0
fi
if [[ $(uname) == Linux ]] && ! command -v llvm-symbolizer >/dev/null && ! command -v llvm-symbolizer-22 >/dev/null; then
    echo "skipped: needs llvm-symbolizer"
    exit 0
fi
census="$ROOT/tools/stack-census.py"

cat >tasks.rig <<'EOF'
use std.par

fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

fun scaled(i: Int, w: Int) -> Int
  spin(w * i)

fun shifted(i: Int, w: Int) -> Int
  spin(w + i)

fun deep(n: Int) -> Int
  if n == 0
    return 0
  a = deep(n - 1)&
  (>a + 1) % 1000003

sub main()
  t = spin(1000)&
  xs = List[Int]()
  for i in 0..64
    !xs.push(i)
  w = 3
  ys = par.map(?xs, |+w, i| scaled(i, w))
  zs = par.map(?xs, |+w, i| shifted(i, w))
  print(>t, ys.len, zs.len, deep(5))
EOF
rig build --release=fast tasks.rig >build.out 2>&1 || fail "rig build: $(cat build.out)"
out=$(./tasks) || fail "the program: $out"
expect_eq "$out" "496491 64 64 5" "the program's output"

row() { grep -F "| rig.sched.spawn" <<<"$1" | grep -F -- "$2"; }
out=$(python3 -I "$census" tasks 2>&1) || fail "the census: $out"
expect_has "$out" "3 task types" "the census's task types"
spin_row=$(row "$out" "| __rig_main.spin |")
[[ $spin_row =~ \|\ [0-9,]+\ B\ \|\ [0-9,]+\ B\ \| ]] || fail "a task of direct calls is bounded: $spin_row"
map_row=$(row "$out" "__rig_main.shifted")
[[ $map_row =~ \|\ [0-9,]+\ B\ \|\ [0-9,]+\ B\ \| ]] || fail "a par.map task, through its FnRef's thunks, is bounded: $map_row"
map_entry=$(awk -F' [|] ' '{print $1}' <<<"$map_row" | tr -d '| ')
deep_row=$(row "$out" "__rig_main.deep")
expect_has "$deep_row" "| unknown: " "a recursive task stays unknown"
grep -qE '\| [0-9,]+ B \|' <<<"$deep_row" && fail "a recursive task has a bound: $deep_row"
out=$(python3 -I "$census" tasks --cold '^rig\.sched\.Poller\.failed$' 2>&1) || fail "the census, --cold: $out"
expect_has "$(row "$out" "__rig_main.deep")" "unknown: a cycle of calls" "a recursive task's reason"

# A frame of 4 KiB or more on arm64 is `sub sp, sp, #N, lsl #12`, which the
# disassembler follows with a `; =0x...` comment: the shift counts, and a
# shift the tool does not know fails closed.
out=$(python3 -I - "$census" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("census", sys.argv[1])
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
class I:
    def __init__(self, op, args): self.op, self.args = op, args
print(m.arm_effect(I("sub", "sp, sp, #0x3, lsl #12   ; =0x3000"), {"regs": {}})[:2])
print(m.arm_effect(I("sub", "sp, sp, #0x3, lsl #1"), {"regs": {}})[0])
print(m.arm_effect(I("add", "sp, sp, #0x10   ; =0x10"), {"regs": {}})[:2])
PY
) || fail "the census's arm64 frames: $out"
expect_eq "$out" "$(printf "('add', 12288)\nbad\n('add', -16)")" "an arm64 frame of 4 KiB or more counts its shift"

# The FnRef fact, failing closed: a runtime that writes `call_fn` outside
# FnRef's own makers, or none the tool can read.
mkdir -p bad/src bad/std
sed 's/return self.call_fn(self.ctx, args);/self.call_fn = undefined; return self.call_fn(self.ctx, args);/' "$ROOT/src/runtime.zig" >bad/src/runtime.zig
cmp -s bad/src/runtime.zig "$ROOT/src/runtime.zig" && fail "the test's edit of FnRef no longer applies"
for src in bad missing; do
    out=$(python3 -I "$census" tasks --rig-src "$src" 2>&1) || fail "the census, --rig-src $src: $out"
    expect_has "$out" "calls through a FnRef: unresolved" "the FnRef fact with --rig-src $src"
    expect_has "$(row "$out" "| $map_entry |")" "| unknown: " "a par.map task without the FnRef fact ($src)"
done

# The rules on instructions, on code made up for each.
python3 -I - "$census" <<'EOF' || fail "the instruction rules (above)"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("census", sys.argv[1])
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

def walk(lines, name="f", arch="aarch64"):
    """Analyse a made-up function: `lines` of (op, args), from 0x1000."""
    fn = sc.Fn(name, 0x1000)
    fn.ins = [sc.Ins(0x1000 + 4 * k, op, args) for k, (op, args) in enumerate(lines)]
    starts = {0x1000, 0x9000}
    sc.analyse(fn, 0x1000 + 4 * len(lines), arch, [(0x1000, 0x10000)], starts, None, {})
    return fn

bad = []
def check(what, ok):
    if not ok:
        bad.append(what)

# A function's address spilled to the stack and loaded back is a direct call.
spill = [("adrp", "x8, 0x9000"), ("add", "x8, x8, #0x0"), ("str", "x8, [sp, #0x8]")]
fn = walk(spill + [("ldr", "x9, [sp, #0x8]"), ("blr", "x9"), ("ret", "")])
check("a spilled address, loaded back, is a direct call", (0, 0x9000) in fn.calls and not fn.icalls)
# The same, with the spill overwritten by a pair, by a narrower store,
# or through the frame pointer, or with the frame's address passed to a
# call in between: the call through the register is unresolved.
for what, mid in [
    ("a store of a pair over the spill", [("stp", "x1, x2, [sp]")]),
    ("a narrower store into the spill", [("str", "w1, [sp, #0xc]")]),
    ("a store through the frame pointer", [("str", "x1, [x29, #0x8]")]),
    ("a call once the frame's address left sp", [("add", "x0, sp, #0x8"), ("bl", "0x9000 <g>")]),
    ("a store through a pointer once the frame's address left sp", [("add", "x0, sp, #0x8"), ("str", "x1, [x3]")]),
]:
    fn = walk(spill + mid + [("ldr", "x9, [sp, #0x8]"), ("blr", "x9"), ("ret", "")])
    check("%s forgets it" % what, bool(fn.icalls) and not fn.why)
# A spill is kept by its place in the frame: after sp moves, the same
# offset from sp is another place.
fn = walk(spill + [("sub", "sp, sp, #0x10"), ("ldr", "x9, [sp, #0x8]"), ("blr", "x9"), ("add", "sp, sp, #0x10"), ("ret", "")])
check("a spill read at the same offset from a moved sp is another place", bool(fn.icalls))
fn = walk(spill + [("sub", "sp, sp, #0x10"), ("ldr", "x9, [sp, #0x18]"), ("blr", "x9"), ("add", "sp, sp, #0x10"), ("ret", "")])
check("a spill read at its place after sp moves", (16, 0x9000) in fn.calls and not fn.icalls)

# clone: Zig's shape leaves the child's branch unwalked; another shape walks it.
child = [("xor", "ebp, ebp"), ("pop", "rdi"), ("call", "r9"), ("mov", "edi, eax"), ("mov", "eax, 0x3c"), ("syscall", "")]
x86 = [("mov", "eax, 0x38"), ("syscall", ""), ("test", "rax, rax"), ("je", "0x1014 <os.linux.x86_64.clone+0x14>"), ("ret", "")] + child
fn = walk(x86, "os.linux.x86_64.clone", "x86_64")
check("x86-64 clone: the child's call is not on the caller's stack", not fn.icalls and not fn.why)
fn = walk(x86, "os.linux.x86_64.not_clone", "x86_64")
check("another function of clone's shape walks the branch", bool(fn.icalls))
x86b = [("mov", "eax, 0x38"), ("syscall", ""), ("test", "rax, rax"), ("je", "0x1018 <os.linux.x86_64.clone+0x18>"), ("nop", ""), ("ret", "")] + child
fn = walk(x86b, "os.linux.x86_64.clone", "x86_64")
check("x86-64 clone of another shape walks the branch", bool(fn.icalls))
arm = [("and", "x1, x1, #0xfffffffffffffff0"), ("stp", "x0, x3, [x1, #-0x10]!"), ("mov", "x8, #0xdc"), ("svc", "#0"), ("cbz", "x0, 0x1018 <os.linux.aarch64.clone+0x18>"), ("ret", ""),
       ("mov", "x29, #0"), ("ldp", "x1, x0, [sp], #0x10"), ("blr", "x1"), ("mov", "x8, #0x5d"), ("svc", "#0")]
fn = walk(arm, "os.linux.aarch64.clone")
check("arm64 clone: the child's call is not on the caller's stack", not fn.icalls and not fn.why)

if bad:
    print("\n".join("failed: " + b for b in bad))
    sys.exit(1)
EOF
exit 0
