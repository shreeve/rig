# RIG_MAP_TRACE=1 at build makes every operation on a built-in Map or Set
# write a 48-byte record to $RIG_MAP_TRACE_FILE, and each Map's types to
# that file's `.types`; tools/map-trace.py reads them. Without the flag,
# the package holds none of it.
source "$ROOT/test/cli/_lib.sh"

cat >ops.rig <<'RIG'
fun fill(n: Int) -> Int
  m: Map[Int, Int] = Map()
  for i in 0..n
    !m.put(i, i * 2)
  m.len

sub main()
  m: Map[String, Int] = Map()
  print(m.has("z"))
  !m.put(String("a"), 1)
  !m.put(String("a"), 2)
  print(m.get("a") ?? 0)
  print((!m).take("a") ?? 0)
  !m.put(String("abcdefghijklmnopqrstuvwxyz0123"), 3)
  !m.clear()
  s: Set[Int] = Set()
  for i in 0..20
    _ = !s.add(i)
  t1 = fill(1000)&
  t2 = fill(1000)&
  t3 = fill(1000)&
  t4 = fill(1000)&
  print(>t1 + >t2 + >t3 + >t4, s.len)
RIG

for mode in "" "--release"; do
  rm -f trace.bin trace.bin.types
  out=$(RIG_MAP_TRACE=1 rig build $mode -o ops ops.rig 2>&1); expect_rc $? 0 "rig build $mode ops.rig: $out"
  out=$(RIG_MAP_TRACE_FILE=trace.bin ./ops 2>&1); expect_rc $? 0 "./ops ($mode): $out"
  expect_eq "$out" $'false\n2\n2\n4000 20' "the program runs as it would ($mode)"
  out=$(python3 - trace.bin <<'PY' 2>&1
import struct, sys
from collections import Counter
path = sys.argv[1]
data = open(path, "rb").read()
assert len(data) % 48 == 0, len(data)
recs = [struct.unpack("<BBHIIIQ24s", data[i:i + 48]) for i in range(0, len(data), 48)]
types = dict((int(l.split("\t")[0]), l.rstrip("\n").split("\t")[1:]) for l in open(path + ".types"))
ops = ["get", "put", "remove", "clear", "new", "drop", "grow", "retain"]
def rec(r):
    op, hit, width, mid, vb, ln, h, head = r
    return ops[op & 7], hit & 1, width, mid, vb, ln, h, head[:min(width, 24)]
rs = [rec(r) for r in recs]
text = [r for r in rs if types[r[3]] == ["String", "Int", "Map"]]
assert [(r[0], r[1], r[2], r[4], r[5], r[7]) for r in text] == [
    ("new", 0, 0, 8, 0, b""),
    ("get", 0, 1, 8, 0, b"z"),
    ("put", 0, 1, 8, 1, b"a"),
    ("put", 1, 1, 8, 1, b"a"),
    ("get", 1, 1, 8, 1, b"a"),
    ("remove", 1, 1, 8, 0, b"a"),
    ("put", 0, 30, 8, 1, b"abcdefghijklmnopqrstuvwx"),
    ("clear", 0, 0, 8, 0, b""),
    ("drop", 0, 0, 0, 0, b""),
], text
assert text[2][6] == text[3][6] == text[4][6] != text[1][6], "a key's hash is the same at each op"
sets = [r for r in rs if types[r[3]] == ["Int", "-", "Set"]]
c = Counter(r[0] for r in sets)
assert c["new"] == 1 and c["put"] == 20 and c["drop"] == 1 and c["grow"] >= 1, c
grows = [r for r in sets if r[0] == "grow"]
assert all(r[6] >= 16 and r[6] & (r[6] - 1) == 0 for r in grows), grows
assert [r[7] for r in sets if r[0] == "put"][3] == (3).to_bytes(8, "little"), "an Int key is its 8 bytes"
ints = [i for i, t in types.items() if t == ["Int", "Int", "Map"]]
assert len(ints) == 4, types
for i in ints:
    c = Counter(r[0] for r in rs if r[3] == i)
    assert c["new"] == 1 and c["put"] == 1000 and c["drop"] == 1 and c["grow"] >= 1, (i, c)
    assert [r[5] for r in rs if r[3] == i and r[0] == "put"] == list(range(1, 1001)), "every put of each task's Map is there, in order"
threads = Counter((r[0] >> 3) | ((r[1] >> 1) << 5) for r in recs)
assert 0 in threads, threads
print("ok", len(recs))
PY
)
  expect_has "$out" "ok " "the records ($mode): $out"
  out=$(python3 "$ROOT/tools/map-trace.py" trace.bin 2>&1); expect_rc $? 0 "tools/map-trace.py: $out"
  expect_has "$out" "Map Int -> Int: " "the reader names each Map's types"
  expect_has "$out" "hit rate" "the reader's hit rate"
done

# Without the flag the package holds no trace: the root module declares
# nothing, the built-in Map has its own methods and no field, and the
# program writes no file. RIG_MAP_TRACE=0 is the same build, to the byte
# (the executable's name is part of its signature on macOS, so both are
# built under one name).
rm -f rig-map-trace.bin rig-map-trace.bin.types
RIG_OUT_DIR=$PWD/out "$RIG" build --release -o prog ops.rig >/dev/null 2>&1 || fail "rig build ops.rig"
mv prog plain
cp out/__rig_main.zig plain.zig && cp out/__rig_std___rig_builtin.zig plain_builtin.zig
RIG_MAP_TRACE=0 RIG_OUT_DIR=$PWD/out "$RIG" build --release -o prog ops.rig >/dev/null 2>&1 || fail "RIG_MAP_TRACE=0 rig build ops.rig"
mv prog zero
out=$(./plain 2>&1); expect_eq "$out" $'false\n2\n2\n4000 20' "the plain program runs"
[[ -e rig-map-trace.bin ]] && fail "a program built without RIG_MAP_TRACE writes no trace"
grep -q "__rig_map_trace" plain.zig && fail "the root module declares no trace"
grep -q "__rig_trace\|mapTrace" plain_builtin.zig && fail "the built-in Map has no trace without the flag"
cmp -s plain.zig out/__rig_main.zig || fail "RIG_MAP_TRACE=0 emits the root module as no flag does"
cmp -s plain_builtin.zig out/__rig_std___rig_builtin.zig || fail "RIG_MAP_TRACE=0 emits the built-in Map as no flag does"
cmp -s plain zero || fail "RIG_MAP_TRACE=0 builds the program no flag does"
exit 0
