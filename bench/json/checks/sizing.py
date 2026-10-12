#!/usr/bin/env python3
"""What each class of std.json's surviving checks costs, in instructions.

usage: cpuq run --cores 2 --label rig:json -- bench/json/checks/sizing.py OUT [--files a,b] [--variants a,b]

Builds rig-safe for each corpus file (the programs `bench-json` makes),
then copies of its emitted package with one class of checks made
unchecked, and counts instructions retired per byte (macOS `/usr/bin/time
-l`: (N parses - 1) / (N - 1) / bytes, the median of 5; the count does
not depend on load, but one run can be off by several percent either way).
A check is made unchecked as a proof would emit it, with runtime safety
off around the original expression, so LLVM keeps the no-overflow fact a
checked add leaves (`rig.addProven`'s form); rewriting `+` as wrapping
`+%` loses that fact and adds instructions.

Each build lands in OUT/<file>-<variant>/prog, the layout of `bench-json
--out`, so `BENCH_OUT=OUT timers/time.py base,sread` times them. The
patches match the text rig emits; one that changes nothing stops the run,
so a change to std.json or to emit shows up rather than measuring nothing.

Variants: base; len (List lengths to Int); tape (the tape entries'
arithmetic); pos (position arithmetic); idx (unproven reads); shl (`m <<
m.leading_zeros()`); sread (the 16-byte read in the string scan's loop);
all (every class but sread). Sizing only: nothing here ships.
"""
import os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
RIG = os.environ.get("RIG", os.path.join(ROOT, "bin", "rig"))
DATA = os.path.join(ROOT, "test", "json", "data", "simd-json")
FILES = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]
JOBS = os.environ.get("CPUQ_CORES", "2")

def sub_lines(src, pred, fn):
    out, n = [], 0
    for l in src.split("\n"):
        if pred(l):
            new = fn(l)
            n += new != l
            l = new
        out.append(l)
    return "\n".join(out), n

_label = [0]
def unchecked(expr):
    _label[0] += 1
    return "(rs%d: { @setRuntimeSafety(false); break :rs%d %s; })" % (_label[0], _label[0], expr)

def exprs(*subs):
    """A line rewrite that makes each listed subexpression unchecked. An
    entry "CONTEXT|EXPR" rewrites EXPR only where CONTEXT holds it."""
    pairs = [tuple(e.split("|")) if "|" in e else (e, e) for e in subs]
    def fn(l):
        for ctx, e in pairs:
            if ctx in l: l = l.replace(ctx, ctx.replace(e, unchecked(e)))
        return l
    return lambda l: any(ctx in l for ctx, _ in pairs), fn

def idx(l):
    l = re.sub(r"rig\.at\((\w+), ([^()]*?(?:\([^()]*\))?[^()]*?)\)", r"rig.atProven(\1, \2, .both)", l)
    return l.replace("rig.readInt(u32, s, at, .big)", "rig.readIntProven(u32, s, at, .big, .both)")

SREAD = "rig.simdRead(@Vector(16, u8), s, i, rig.Endian.little)"
PATCHES = {
    "len": [("rig/runtime.zig", lambda l: "if (@as(u64, n) > max_len) lenPanic();" in l,
             lambda l: l.replace("if (@as(u64, n) > max_len) lenPanic();",
                                 "{ @setRuntimeSafety(false); if (@as(u64, n) > max_len) unreachable; }"))],
    "tape": [("json.zig",) + exprs(
        "(rig.len(self.tape.len) * 2) + @as(i64, if (is_object) 1 else 0)", "(rig.len(self.tape.len) * 16) + tag",
        "((start * 16) + tag) + 1", "((@shlExact(@as(i64, offset), @intCast(27)) + n) * 16) + tag",
        "(rig.len(self.floats.len) * 16) + rig.rt(T_FLOAT)", "(rig.len(self.ints.len) * 16) + rig.rt(T_BIG_INT)")],
    "idx": [("json.zig", lambda l: "rig.at(" in l or "rig.readInt(u32, s, at, .big)" in l, idx)],
    "pos": [("json.zig",) + exprs(
        "i - first", "i - dot", "int_digits + frac_digits", "return i + k;|i + k", "(i + 16)", "(i + 8)",
        "(at + width)", "(at + k)", "(i + 1)",
        "rig.at(s, at + 1)|at + 1", "rig.at(s, at + k)|at + k", "rig.at(src, at + k)|at + k",
        "rig.atProven(s, at + 1, .both)|at + 1", "rig.atProven(s, at + k, .both)|at + k",
        "rig.atProven(src, at + k, .both)|at + k")],
    "shl": [("json.zig",) + exprs("@shlExact(@as(u64, m), @intCast(lz))", "@shlExact(@as(u64, mantissa), @intCast(shift))")],
    "sread": [("json.zig", lambda l: "rig.maskFirst(rig.rt(special(" + SREAD in l,
               lambda l: l.replace(SREAD, unchecked("@as(*align(1) const @Vector(16, u8), @ptrCast(s.ptr + @as(usize, @intCast(i)))).*")))],
}
# idx before pos: pos matches the reads idx makes.
PATCHES["all"] = PATCHES["len"] + PATCHES["tape"] + PATCHES["idx"] + PATCHES["pos"] + PATCHES["shl"]

def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0: sys.exit("failed: %s\n%s%s" % (" ".join(cmd), p.stdout[-2000:], p.stderr[-2000:]))
    return p

def build(out, f, variant):
    exe = os.path.join(out, "%s-%s" % (f, variant), "prog")
    if os.path.exists(exe): return exe
    progs = os.path.join(out, "programs")
    if not os.path.exists(os.path.join(progs, "%s-rig-safe" % f, "main.rig")):
        run([os.path.join(ROOT, "bench", "json", "bench-json"), "--out", progs, "--build-only",
             "--variants", "rig-safe", "--files", f])
    pkg = os.path.join(out, "%s-pkg" % f)
    if not os.path.exists(pkg):
        run([RIG, "build", "--release", "-o", os.path.join(out, "%s-rig" % f),
             os.path.join(progs, "%s-rig-safe" % f, "main.rig")], env=dict(os.environ, RIG_OUT_DIR=pkg))
    vp = os.path.join(out, "%s-%s" % (f, variant))
    shutil.rmtree(vp, ignore_errors=True)
    shutil.copytree(pkg, vp, ignore=shutil.ignore_patterns(".zig-cache"))
    for path, pred, fn in PATCHES.get(variant, []):
        p = os.path.join(vp, path)
        text, n = sub_lines(open(p).read(), pred, fn)
        if n == 0: sys.exit("%s: a patch on %s changed nothing; the emitted text moved" % (variant, path))
        open(p, "w").write(text)
    run(["zig", "build-exe", "-Osafe", "-j" + JOBS, "--cache-dir", os.path.join(out, ".zc-%s" % variant),
         "__rig_main.zig", "-femit-bin=" + exe], cwd=vp)
    return exe

def instructions(exe, n):
    p = subprocess.run(["/usr/bin/time", "-l", exe, str(n)], capture_output=True, text=True)
    if p.returncode != 0: sys.exit("%s failed: %s" % (exe, p.stderr[-500:]))
    return int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1))

def per_byte(exe, size):
    n = max(21, int(6e7 / size))
    return sorted((instructions(exe, n) - instructions(exe, 1)) / (n - 1) / size for _ in range(5))[2]

def cell(v, base):
    pct = 100 * (v / base - 1)
    return "%.2f (%s)" % (v, "the same" if round(pct, 1) == 0 else "%.1f%% %s" % (abs(pct), "more" if pct > 0 else "fewer"))

def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    out, args = sys.argv[1], sys.argv[2:]
    files = args[args.index("--files") + 1].split(",") if "--files" in args else FILES
    variants = args[args.index("--variants") + 1].split(",") if "--variants" in args else ["base", "len", "tape", "pos", "idx", "shl", "sread", "all"]
    if variants[0] != "base": variants.insert(0, "base")
    os.makedirs(out, exist_ok=True)
    res = {}
    for f in files:
        size = os.path.getsize(os.path.join(DATA, f + ".json"))
        for v in variants:
            res[f, v] = per_byte(build(out, f, v), size)
            print("%-15s %-6s %.3f instructions/byte" % (f, v, res[f, v]), file=sys.stderr, flush=True)
    print("instructions retired per byte, and against base")
    print("| file | " + " | ".join(variants) + " |")
    print("|---|" + "---:|" * len(variants))
    for f in files:
        b = res[f, "base"]
        print("| %s | %s |" % (f, " | ".join(["%.2f" % b] + [cell(res[f, v], b) for v in variants[1:]])))

main()
