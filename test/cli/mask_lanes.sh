# timeout: 120
# `m.lanes()` walks a mask's true lanes in the target's fastest form, read
# from the assembly Zig writes for each (docs/internals/INTERNALS.md,
# "Vectors"). Each lane is one turn of a loop held in one general
# register: a count of trailing zeros, the clear of the lowest bit, and
# the branch back, with no vector instruction and no memory access. The
# kernels add each lane's position to a total, two adds a lane.
# - NEON: a 16-lane mask is its nibble mask (`cmeq.16b`, `shrn.8b`,
#   `fmov`), an 8-lane one its bytes (`cmeq.8b`, `fmov`), with no
#   reduction (`addv`) and no constant from memory, where `bits()` has
#   both; the lane is `ctz` (`rbit` + `clz` before CSSC) shifted by a
#   constant, which the add takes for free.
# - x86-64: `pcmpeqb` and `pmovmskb` (`vpmovmskb` of 32 lanes on
#   x86-64-v3), then `bsf` or `tzcnt`, and `blsr` with BMI1.
source "$ROOT/test/cli/_lib.sh"

# The kernels are the program of the case "mask lanes kernels" in
# test/rig/types-simd.rig.test, which checks what they compute; the
# runner writes it out under $RIG_TESTS. `rig emit` writes its package,
# which Zig builds here.
[[ -n ${RIG_TESTS:-} ]] || fail "RIG_TESTS is not set: run this script with test/rig.rip"
cp "$RIG_TESTS/behavior/types/mask_lanes_kernels.rig" ml.rig || fail "no program of the case \"mask lanes kernels\""
out=$(rig emit ml.rig 2>&1) || fail "emit: $out"
pkg=$RIG_OUT_DIR/programs/ml
[[ -d $pkg ]] || pkg=$RIG_OUT_DIR
cat >"$pkg/ml_kernels.zig" <<'ZIG'
const m = @import("__rig_main.zig");
export fn x_lanes16(p: [*]const u8, n: usize, tag: u8) i64 {
    return m.lanes16(p[0..n], tag);
}
export fn x_bits16(p: [*]const u8, n: usize, tag: u8) i64 {
    return m.bits16(p[0..n], tag);
}
export fn x_lanes8(p: [*]const u8, n: usize, tag: u8) i64 {
    return m.lanes8(p[0..n], tag);
}
export fn x_lanes32(p: [*]const u8, n: usize, tag: u8) i64 {
    return m.lanes32(p[0..n], tag);
}
export fn x_lanes64(p: [*]const u8, n: usize, tag: u8) i64 {
    return m.lanes64(p[0..n], tag);
}
ZIG

# asm <name> <target> <cpu>: the kernels' assembly, in $name.s.
asm() {
    (cd "$pkg" && zig_once "$PWD/../$1.s" -- . -- "${ZIG:-zig}" build-obj -O ReleaseFast -target "$2" -mcpu="$3" -femit-asm="$PWD/../$1.s" -fno-emit-bin ml_kernels.zig) >build.log 2>&1 || fail "$1: $(cat build.log)"
}
asm m1 aarch64-macos apple_m1
asm m5 aarch64-macos apple_m5
asm x64 x86_64-linux x86_64
asm x64v3 x86_64-linux x86_64_v3

python3 - "$pkg/.." <<'PY' || exit 1
import re, sys

def kernels(path):
    """Each exported kernel's instructions, labels kept as `L:`."""
    out, name = {}, None
    for line in open(path):
        m = re.match(r'^"?_?(?:ml_kernels\.)?(x_\w+)"?:', line)
        if m:
            name = m.group(1); out[name] = []; continue
        if re.match(r'^("[^"]+"|[A-Za-z_.$][\w.$]*):', line) and not line.startswith(("L", ".L")):
            name = None; continue
        t = line.split(";")[0].split("//")[0].strip()
        if not name or not t:
            continue
        if re.match(r'^\.?L\w+:', t):
            if re.match(r'^\.?LBB', t): out[name].append(t)
            continue
        if t.startswith((".", "#")) or "=" in t:
            continue
        out[name].append(t)
    return out

def lane_loop(body):
    """The block that branches back to its own label: a lane's turn."""
    loops = []
    for i, t in enumerate(body):
        if not t.endswith(":"):
            continue
        label = t[:-1]
        block = []
        for u in body[i + 1:]:
            if u.endswith(":"): break
            block.append(u)
            if re.search(r'\s' + re.escape(label) + r'$', u):
                loops.append(block)
                break
    return loops

def count(body, pat):
    return sum(1 for t in body if re.search(pat, t))

bad, shown = [], []
d = sys.argv[1]
ctz = r"\b(rbit|ctz|bsf|tzcnt)\b"
vector = r"\.(16b|8b|8h|4s|2d)\b|\b[qdvhsb]\d+\b|xmm|ymm"
memory = r"^(?!lea\b)\S+\s.*(\[|\(%)"
for t, most in (("m1", 5), ("m5", 4), ("x64", 5), ("x64v3", 4)):
    ks = kernels(f"{d}/{t}.s")
    for k in ("x_lanes16", "x_bits16", "x_lanes8", "x_lanes32", "x_lanes64"):
        if k not in ks:
            bad.append(f"{t}: no kernel {k}"); continue
        loops = [b for b in lane_loop(ks[k]) if count(b, ctz)]
        if len(loops) == 0:
            bad.append(f"{t} {k}: no lane loop"); continue
        for b in loops:
            # The total's two adds are the kernel's, not the walk's.
            lane = len(b) - 2
            shown.append(f"{t} {k}: {lane}")
            if k != "x_bits16" and lane > most: bad.append(f"{t} {k}: {lane} instructions a lane, over {most}: {b}")
            if count(b, vector): bad.append(f"{t} {k}: a vector instruction in the lane loop: {b}")
            if count(b, memory): bad.append(f"{t} {k}: memory in the lane loop: {b}")
    if t.startswith("m"):
        for k, form in (("x_lanes16", r"\bshrn(\.8b)?\b"), ("x_lanes8", r"\bcmeq\.8b\b")):
            if k in ks and not count(ks[k], form): bad.append(f"{t} {k}: not the NEON form ({form})")
        for k in ("x_lanes16", "x_lanes8"):
            if k in ks and count(ks[k], r"\baddv\b|lCPI|\bzip1\b"): bad.append(f"{t} {k}: a reduction or a constant from memory")
        if "x_bits16" in ks and not count(ks["x_bits16"], r"\baddv\b"): bad.append(f"{t} x_bits16: no addv, so the baseline changed")
        if "x_lanes64" in ks and count(ks["x_lanes64"], r"\b(umov|ins|mov\.b)\b"): bad.append(f"{t} x_lanes64: moves lanes one by one")
    else:
        for k in ("x_lanes16", "x_lanes8", "x_lanes32", "x_lanes64"):
            if k in ks and not count(ks[k], r"\bv?pmovmskb\b"): bad.append(f"{t} {k}: no pmovmskb")
            if k in ks and count(ks[k], r"\b(v?pextrb|v?pinsrb)\b"): bad.append(f"{t} {k}: moves lanes one by one")
        if t == "x64v3" and not count(ks.get("x_lanes16", []), r"\bblsr\b"): bad.append(f"{t} x_lanes16: no blsr")
if bad:
    print("FAIL: " + "; ".join(bad) + "\ninstructions a lane: " + ", ".join(shown)); sys.exit(1)
if len(sys.argv) > 2: print("instructions a lane: " + ", ".join(shown))
PY
