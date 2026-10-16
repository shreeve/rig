# timeout: 900
# Masks of 32 and 64 lanes lower to the fast form on every target, read
# from the assembly Zig writes for each (docs/INTERNALS.md, "Vectors"):
# - NEON: `bits()` is the pairwise-add reduction, four `addp` for 64 lanes,
#   and `m.not().bits()` flips the bits after it (`rig.maskBitsNot`), with
#   no `mvn` per 16 lanes;
# - x86 without AVX-512 (baseline SSE2 and x86-64-v3): no mask is rebuilt
#   a lane at a time (`pextrb`, `pinsrb`, or bytes through the stack), even
#   where a classifier shifts the bits with a checked `<<`, which LLVM
#   would otherwise do on the lanes (`maskBitsOpaque`), and a use of
#   some of the bits (`bits() & 0xFF`, `bits() >> 63`) takes one piece's
#   `pmovmskb` only;
# - WASM SIMD: `any()` and `all()` of a flipped 64-lane mask move no lane;
# - x86 debug builds, which Zig's own backend makes, compile.
source "$ROOT/test/cli/_lib.sh"

cat >wm.rig <<'RIG'
type W64 = Simd[U8, 64]
type W32 = Simd[U8, 32]

fun nonspace64(s: ?String) -> Int
  n = 0
  i = 0
  while i + 64 <= s.len : i += 64
    v = s.read[W64](i)
    n += ((v == 0x20) | (v == 0x0A) | (v == 0x0D) | (v == 0x09)).not().bits().count_ones()
  n

fun nonspace32(s: ?String) -> Int
  n = 0
  i = 0
  while i + 32 <= s.len : i += 32
    v = s.read[W32](i)
    n += ((v == 0x20) | (v == 0x0A)).not().bits().count_ones()
  n

fun starts(s: ?String) -> U64
  prev: U64 = 0
  acc: U64 = 0
  i = 0
  while i + 64 <= s.len : i += 64
    v = s.read[W64](i)
    q = (v == 0x22).bits()
    bs = (v == 0x5C).bits()
    lo = v | 0x20
    op = ((lo == 0x7B) | (lo == 0x7D) | (v == 0x3A) | (v == 0x2C)).bits()
    ws = ((v == 0x20) | (v == 0x0A) | (v == 0x0D) | (v == 0x09)).bits()
    scalar = (op | ws).not()
    follows = (scalar << 1) | prev
    prev = scalar >> 63
    acc = acc ^ ((op | (scalar & follows.not())) & (q | bs).not())
  acc

fun spaces(s: ?String) -> Int
  n = 0
  i = 0
  while i + 64 <= s.len : i += 64
    m = (s.read[W64](i) == 0x20) | (s.read[W64](i) == 0x0A)
    n += 1 if m.not().any() else 0
    n += 2 if m.not().all() else 0
  n

fun ends(s: ?String) -> U64
  acc: U64 = 0
  i = 0
  while i + 64 <= s.len : i += 64
    m = s.read[W64](i) == 0x22
    acc = acc +% (m.bits() & 0xFF) +% (m.bits() >> 63)
  acc

fun low(s: ?String) -> U64
  acc: U64 = 0
  i = 0
  while i + 64 <= s.len : i += 64
    acc = acc +% ((s.read[W64](i) == 0x3A).bits() & 0xFF)
  acc

sub main()
  s = String()
  # Each block of 64 ends in a space, so `starts` shifts out no bit.
  for k in 0..1024
    !s.push(0x20 if k % 64 == 63 else U8(" \x0a{\"a\": 1, \"b\": [2, 3]}\x09\x0d:x"[k % 26]))
  print(nonspace64(?s), nonspace32(?s), starts(?s), spaces(?s), ends(?s), low(?s))
RIG
out=$(rig run --release wm.rig 2>&1) || fail "run: $out"
expect_eq "$out" "699 775 1309964357605222691 16 882 410" "run"
out=$(rig emit wm.rig 2>&1) || fail "emit: $out"
expect_has "$out" 'rig.maskBitsNot(rig.maskOr(' "m.not().bits() flips the bits"
grep -qF 'rig.maskBits(rig.maskNot(' <<<"$out" && fail "m.not().bits() flips the lanes: $out"
expect_has "$out" 'rig.maskAny(rig.maskNot(m))' "m.not().any() keeps its lanes"
pkg=$RIG_OUT_DIR/programs/wm
cat >"$pkg/wm_kernels.zig" <<'ZIG'
const m = @import("__rig_main.zig");
export fn x_nonspace64(p: [*]const u8, n: usize) i64 {
    return m.nonspace64(p[0..n]);
}
export fn x_nonspace32(p: [*]const u8, n: usize) i64 {
    return m.nonspace32(p[0..n]);
}
export fn x_starts(p: [*]const u8, n: usize) u64 {
    return m.starts(p[0..n]);
}
export fn x_spaces(p: [*]const u8, n: usize) i64 {
    return m.spaces(p[0..n]);
}
export fn x_ends(p: [*]const u8, n: usize) u64 {
    return m.ends(p[0..n]);
}
export fn x_low(p: [*]const u8, n: usize) u64 {
    return m.low(p[0..n]);
}
ZIG

# asm <name> <mode> <target> <cpu>: the kernels' assembly, in $name.s.
asm() {
    (cd "$pkg" && "${ZIG:-zig}" build-obj -O "$2" -target "$3" -mcpu="$4" -femit-asm="$PWD/../$1.s" -fno-emit-bin wm_kernels.zig) >build.log 2>&1 || fail "$1: $(cat build.log)"
}
asm a64 ReleaseSafe aarch64-macos apple_m1
asm x64 ReleaseSafe x86_64-linux x86_64
asm x64v3 ReleaseSafe x86_64-linux x86_64_v3
asm wasm ReleaseSafe wasm32-freestanding generic+simd128
(cd "$pkg" && "${ZIG:-zig}" build-obj -O Debug -target x86_64-linux -fno-emit-asm wm_kernels.zig) >build.log 2>&1 || fail "x86 debug: $(cat build.log)"

python3 - "$pkg/.." <<'PY' || exit 1
import re, sys

def bodies(path):
    """Each exported kernel's instructions."""
    out, name = {}, None
    for line in open(path):
        m = re.match(r'^"?_?(?:wm_kernels\.)?(x_\w+)"?:', line)
        if m:
            name = m.group(1); out[name] = []; continue
        if re.match(r'^("[^"]+"|[A-Za-z_.$][\w.$]*):', line) and not line.startswith(("L", ".L")):
            name = None; continue
        t = line.strip()
        if name and t and not t.startswith((".", "#", ";", "//")):
            out[name].append(t)
    return out

def count(body, pat):
    return sum(1 for t in body if re.search(pat, t))

bad = []
d = sys.argv[1]
a64 = bodies(f"{d}/a64.s")
for k, adds in (("x_nonspace64", 4), ("x_nonspace32", 3)):
    if count(a64[k], r"\baddp\b") != adds: bad.append(f"a64 {k}: not {adds} addp")
    if count(a64[k], r"\bmvn\.16b\b"): bad.append(f"a64 {k}: flips lanes (mvn.16b)")
lanes = r"\b(v?pextrb|v?pinsrb|v?pextrw|v?pinsrw)\b|byte ptr \[r[bs]p"
for t in ("x64", "x64v3"):
    x64 = bodies(f"{d}/{t}.s")
    for k, body in x64.items():
        if count(body, lanes): bad.append(f"{t} {k}: moves lanes one by one")
        if not count(body, r"\bv?pmovmskb\b"): bad.append(f"{t} {k}: no pmovmskb")
    # Some of the bits take only their pieces' `pmovmskb`.
    for k, most in (("x_low", 1), ("x_ends", 2)):
        if count(x64[k], r"\bv?pmovmskb\b") > most: bad.append(f"{t} {k}: more than {most} pmovmskb")
wasm = bodies(f"{d}/wasm.s")
for k, body in wasm.items():
    if count(body, r"extract_lane|replace_lane"): bad.append(f"wasm {k}: moves lanes one by one")
if len(a64) != 6 or len(wasm) != 6: bad.append(f"kernels found: a64 {len(a64)}, wasm {len(wasm)}")
if bad:
    print("FAIL: " + "; ".join(bad)); sys.exit(1)
PY
