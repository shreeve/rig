# A large embedded run added to an empty List: mapped from the program's
# own file in a Linux release build (`alloc.mapRun`), copied elsewhere,
# with the same results. Each List owns its elements: a write to one,
# before and after it grows, is its own, and a List made from the same
# bytes again reads them as they are. On Linux, the release build opens
# its own file (`/proc/self/exe`) to map the run; strace shows it.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

python3 -c "
import struct
open('recs.bin', 'wb').write(b''.join(struct.pack('<II', i, i * 3) for i in range(32768)))" || fail "write recs.bin"
cat >main.rig <<'R'
obj Rec exact
  a: U32
  b: U32

sub main()
  xs: List[Rec] = List()
  !xs.extend_from_bytes($embed("recs.bin"))
  ys: List[Rec] = List()
  !ys.extend_from_bytes($embed("recs.bin"))
  xs[5].a = 99
  !xs.push(Rec(a: 1, b: 2))
  xs[6].b = 7
  zs: List[Rec] = List()
  !zs.extend_from_bytes($embed("recs.bin"))
  print(xs.len, xs[5].a, xs[6].b, ys[5].a, ys[6].b, ys.len, zs[5].a, xs[xs.len - 1].a)
R
want="32769 99 7 5 18 32768 5 1"
expect_eq "$(rig run main.rig 2>&1)" "$want" "a debug build, which copies"
(rig build --release -o rel main.rig) || fail "a release build"
expect_eq "$(./rel)" "$want" "a release build"
if [[ $(uname) == Linux ]] && command -v strace >/dev/null; then
    calls=$(strace -f -e trace=open,openat ./rel 2>&1 >/dev/null)
    expect_has "$calls" "/proc/self/exe" "the release build maps its run"
fi
