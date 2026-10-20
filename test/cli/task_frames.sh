# timeout: 900
# A task's guard is at least twice the largest frame the compiler counts
# in the program (`sema.taskGuard`), and never under `sema.min_task_guard`
# (16 MiB). Every frame it does not count, the runtime's, the scheduler's,
# and the Zig library's they call, is under half that, so a frame that
# overflows a task's stack faults in the guard, never past it. It reads
# Zig's aarch64 assembly on an aarch64 Mac, and the program's x86_64 code
# (objdump) on Linux, in every build mode, of a program that makes tasks
# and has a large frame of its own.
source "$ROOT/test/cli/_lib.sh"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) how=asm ;;
    Linux/x86_64)
        command -v objdump >/dev/null || { echo "skipped: no objdump"; exit 0; }
        how=objdump ;;
    *) echo "skipped: reads aarch64 assembly or x86_64 code"; exit 0 ;;
esac

times=$(sed -n 's/^pub const min_task_guard: u64 = \([0-9]*\) \* noinline_reach;.*/\1/p' "$ROOT/src/sema.zig")
shift=$(sed -n 's/^pub const noinline_reach: u64 = 1 << \([0-9]*\);.*/\1/p' "$ROOT/src/sema.zig")
[[ -n $times && -n $shift ]] || fail "no min_task_guard or noinline_reach in src/sema.zig"
half=$(( times * (1 << shift) / 2 ))

# A program that makes tasks, waits on them and on sets, cancels, sleeps,
# reads a file, prints, and has a large frame of its own.
cat >tasks.rig <<'EOF2'
use std.file
use std.task
use std.time

fun big(k: Int) -> Int
  b = [100000 of k]
  b[k] + b[99999]

fun nap() -> Int!
  time.sleep(time.MS)!
  task.check()!
  1

sub main()
  t = big(3)&
  ts = Tasks[Int!]()
  for 0..4
    !ts.add(nap()&)
  xs = >ts catch List[Int]()
  u = nap()&
  r = <u.cancel() catch 0
  text = file.read("tasks.rig") ?? String("")
  print(>t, xs.len, r, text.len > 0)
EOF2

if [[ $how == asm ]]; then
    rig emit tasks.rig >/dev/null 2>&1 || fail "emit tasks.rig"
    pkg=$RIG_OUT_DIR/programs/tasks
    for mode in Debug ReleaseSafe ReleaseFast; do
        (cd "$pkg" && zig_once "$PWD/../tasks-$mode.s" -- . -- "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../tasks-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode assembly: $(cat build.log)"
        python3 "$ROOT/test/cli/_frames.py" --all "$RIG_OUT_DIR/programs/tasks-$mode.s" >"real-$mode.txt"
    done
else
    for mode in Debug ReleaseSafe ReleaseFast; do
        flag=; [[ $mode == ReleaseSafe ]] && flag=--release; [[ $mode == ReleaseFast ]] && flag=--release=fast
        rig build $flag -o "tasks-$mode" tasks.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
        objdump -d -M intel --no-show-raw-insn "tasks-$mode" >"tasks-$mode.dis"
        python3 "$ROOT/test/cli/_frames.py" --all "tasks-$mode.dis" >"real-$mode.txt"
    done
fi

python3 - "$half" real-Debug.txt real-ReleaseSafe.txt real-ReleaseFast.txt <<'PY' || exit 1
import sys
half = int(sys.argv[1])
bad = []
for path in sys.argv[2:]:
    real = [l.rsplit(None, 1) for l in open(path) if l.strip()]
    if len(real) < 100:
        bad.append(f'{path}: only {len(real)} functions found')
    # The program's own frames are counted (`__rig_main.`); the rest are
    # not.
    if not any(n.startswith('_rig_main.') or n.startswith('__rig_main.') for n, b in real):
        bad.append(f'{path}: none of the program\'s own functions found')
    for n, b in real:
        if not n.lstrip('_').startswith('rig_main.') and int(b) >= half:
            bad.append(f'{path}: `{n}` reserves {b} bytes, half the smallest guard ({half}) or more')
if bad:
    print('FAIL: ' + '\n'.join(bad))
    sys.exit(1)
PY
exit 0
