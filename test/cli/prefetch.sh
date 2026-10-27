# timeout: 120
# `xs.prefetch(i)` is one prefetch instruction, read from the assembly
# Zig writes for each target: `prfm pldl1keep` on arm64 and `prefetcht0`
# on x86-64, with no range test, branch, or call (src/runtime.zig,
# `prefetch`).
source "$ROOT/test/cli/_lib.sh"

# The kernels are the program of the case "slice prefetch kernels" in
# test/rig/types-slice.rig.test, which checks what they compute; the
# runner writes it out under $RIG_TESTS. `rig emit` writes its package,
# which Zig builds here.
[[ -n ${RIG_TESTS:-} ]] || fail "RIG_TESTS is not set: run this script with test/rig.rip"
cp "$RIG_TESTS/behavior/types/slice_prefetch_kernels.rig" pk.rig || fail "no program of the case \"slice prefetch kernels\""
out=$(rig emit pk.rig 2>&1) || fail "emit: $out"
pkg=$RIG_OUT_DIR/programs/pk
[[ -d $pkg ]] || pkg=$RIG_OUT_DIR
cat >"$pkg/pk_kernels.zig" <<'ZIG'
const m = @import("__rig_main.zig");
export fn x_warm(p: [*]const i64, n: usize, i: i64) void {
    m.warm(p[0..n], i);
}
export fn x_sum_ahead(p: [*]const i64, n: usize, k: [*]const i64, kn: usize) i64 {
    return m.sum_ahead(p[0..n], k[0..kn]);
}
ZIG

# asm <name> <target> <cpu>: the kernels' assembly, in $name.s.
asm() {
    (cd "$pkg" && zig_once "$PWD/../$1.s" -- . -- "${ZIG:-zig}" build-obj -O ReleaseFast -target "$2" -mcpu="$3" -femit-asm="$PWD/../$1.s" -fno-emit-bin pk_kernels.zig) >build.log 2>&1 || fail "$1: $(cat build.log)"
}
asm m1 aarch64-macos apple_m1
asm m5 aarch64-macos apple_m5
asm x64 x86_64-linux x86_64
asm x64v3 x86_64-linux x86_64_v3

python3 - "$pkg/.." <<'PY' || exit 1
import re, sys

def kernels(path):
    """Each exported kernel's instructions, labels dropped."""
    out, name = {}, None
    for line in open(path):
        m = re.match(r'^"?_?(?:pk_kernels\.)?(x_\w+)"?:', line)
        if m:
            name = m.group(1); out[name] = []; continue
        if re.match(r'^("[^"]+"|[A-Za-z_.$][\w.$]*):', line) and not line.startswith(("L", ".L")):
            name = None; continue
        t = line.split(";")[0].split("//")[0].strip()
        if not name or not t or t.endswith(":") or t.startswith((".", "#")) or "=" in t:
            continue
        out[name].append(t)
    return out

def count(body, pat):
    return sum(1 for t in body if re.search(pat, t))

bad = []
d = sys.argv[1]
for t in ("m1", "m5", "x64", "x64v3"):
    ks = kernels(f"{d}/{t}.s")
    arm = t.startswith("m")
    fetch = r"^prfm\s+pldl1keep\b" if arm else r"^prefetcht0\b"
    cond = r"^b\.\w+|^(cbn?z|tbn?z)\b" if arm else r"^j(?!mp)\w+"
    for k in ("x_warm", "x_sum_ahead"):
        if k not in ks:
            bad.append(f"{t}: no kernel {k}"); continue
        if count(ks[k], fetch) != 1: bad.append(f"{t} {k}: {count(ks[k], fetch)} prefetches, not 1: {ks[k]}")
    w = ks.get("x_warm", [])
    if count(w, r"^(cmp|cmn|test|tst)\b"): bad.append(f"{t} x_warm: a range test: {w}")
    if count(w, cond): bad.append(f"{t} x_warm: a branch: {w}")
    if count(w, r"^(bl|call)\b"): bad.append(f"{t} x_warm: a call: {w}")
if bad:
    print("FAIL: " + "; ".join(bad)); sys.exit(1)
PY
