# timeout: 600
# What a thread and a waiting task hold of their own. Each thread's
# alternate signal stack is a mapping the runtime makes (`rig.AltStack`),
# untouched until a signal runs on it, so the program's thread-local
# storage holds no 256 KiB array of Zig's, which every worker and pool
# thread would keep resident. A task that blocks on another touches the
# stack `sched.block` reserves, under a page; its deadlock walk, which
# few waits run, has a frame of its own (`sched.walkFrom`). It reads the
# thread-local sections (otool on macOS, readelf on Linux) and Zig's
# aarch64 assembly or the program's x86_64 code (objdump), in the
# release modes, of a program that makes tasks and actors.
source "$ROOT/test/cli/_lib.sh"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) how=asm ;;
    Linux/x86_64)
        command -v objdump >/dev/null && command -v readelf >/dev/null || { echo "skipped: no objdump or readelf"; exit 0; }
        how=objdump ;;
    *) echo "skipped: reads aarch64 assembly or x86_64 code"; exit 0 ;;
esac

cat >waits.rig <<'EOF2'
obj Counter
  hits: Int

  fun add(!@, n: Int) -> Int
    @hits += n
    @hits

sub hammer(c: *Actor[Counter], n: Int)
  for 0..n
    _ = (!c).add(1)

sub main()
  c = *Actor(Counter(hits: 0))
  ts = Tasks[Void]()
  for 0..4
    !ts.add(hammer(+c, 1000)&)
  >ts
  print((!c).add(0))
EOF2

for mode in ReleaseSafe ReleaseFast; do
    flag=--release; [[ $mode == ReleaseFast ]] && flag=--release=fast
    rig build $flag -o "waits-$mode" waits.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
    out=$("./waits-$mode") || fail "run $mode: $out"
    expect_eq "$out" 4000 "the program's answer, $mode"
    if [[ $how == asm ]]; then
        tls=$(otool -l "waits-$mode" | python3 -c '
import re, sys
text = sys.stdin.read()
print(sum(int(m.group(1), 16) for m in re.finditer(r"sectname __thread_(?:data|bss)\n(?:.*\n){2}\s*size (0x[0-9a-f]+)", text)))')
    else
        tls=$(readelf -lW "waits-$mode" | awk '$1 == "TLS" { print $6 }')
        [[ -n $tls ]] && tls=$((tls))
    fi
    [[ -n $tls ]] || fail "$mode: no thread-local storage found"
    (( tls < 4096 )) || fail "$mode: the thread-local storage is $tls bytes, a page or more"
done

if [[ $how == asm ]]; then
    rig emit waits.rig >/dev/null 2>&1 || fail "emit waits.rig"
    pkg=$RIG_OUT_DIR/programs/waits
    for mode in ReleaseSafe ReleaseFast; do
        (cd "$pkg" && zig_once "$PWD/../waits-$mode.s" -- . -- "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../waits-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode assembly: $(cat build.log)"
        python3 "$ROOT/test/cli/_frames.py" --all "$RIG_OUT_DIR/programs/waits-$mode.s" >"frames-$mode.txt"
    done
else
    for mode in ReleaseSafe ReleaseFast; do
        objdump -d -M intel --no-show-raw-insn "waits-$mode" >"waits-$mode.dis"
        python3 "$ROOT/test/cli/_frames.py" --all "waits-$mode.dis" >"frames-$mode.txt"
    done
fi

for mode in ReleaseSafe ReleaseFast; do
    grep -q '^rig\.sched\.walkFrom ' "frames-$mode.txt" || fail "$mode: no frame of its own for the deadlock walk (rig.sched.walkFrom)"
    block=$(awk '$1 == "rig.sched.block" { print $2 }' "frames-$mode.txt")
    [[ -z $block ]] || (( block < 4096 )) || fail "$mode: rig.sched.block reserves $block bytes, a page or more"
done
exit 0
