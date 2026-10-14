#!/usr/bin/env python3
"""The check-speed guard: how fast `rig check` is, on a ReleaseSafe build
of the compiler, against bench/check/guard.txt. Three gates:

  - instructions: the instructions retired by `rig check` of the
    workload (bench/check/gen.py, `workload`: every generator in one
    program, about the size of Trig's parser), the median of 5, more
    than 2% above the baseline fails;
  - passes: each pass's time (`rig check --time`), the best of 7, more
    than 20% and 0.25 ms above its baseline fails. Times move with the
    machine's load, so above a load of 5 (`uptime`'s last minute) this
    gate is skipped, and says so;
  - scaling: for each dimension (modules, variants, fields, functions,
    statements), the instructions of checking a program n and 8n large,
    less those of one of size 1 (what every program costs), give an
    exponent, log(I(8n) / I(n)) / log 8; above 1.15 fails. A pass whose
    time grows with the square of something shows here at once.

Instruction counts come from `/usr/bin/time -l`, so the guard runs on
macOS only. After a change meant to move the baseline (a faster pass, a
new Zig), `--update` writes it, and it is committed.

usage: cpuq run --cores 2 --label rig:check -- bench/check/guard.py [--update] [--rig PATH]

Without --rig it builds the compiler (`zig build -Doptimize=ReleaseSafe`)
into a temporary directory.
"""
import math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import gen  # noqa: E402

BASE = os.path.join(HERE, "guard.txt")
INSTR_LIMIT = 1.02
PASS_LIMIT = 1.20
PASS_FLOOR_MS = 0.25
LOAD_LIMIT = 5.0
EXP_LIMIT = 1.15
# Each dimension's n (scale.py's sizes); the pair is n and 8n.
SCALING = {"modules": 25, "variants": 250, "fields": 250, "funcs": 1000, "stmts": 1000}


def write(d, files):
    os.makedirs(d, exist_ok=True)
    for name, text in files.items():
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
    return d


def instructions(rig, d):
    p = subprocess.run(["/usr/bin/time", "-l", rig, "check", "main.rig"], cwd=d, capture_output=True, text=True)
    m = re.search(r"(\d+)\s+instructions retired", p.stderr)
    if p.returncode != 0 or not m:
        sys.exit("guard: rig check in %s failed: %s" % (d, p.stderr[-400:]))
    return int(m.group(1))


def median_instructions(rig, d, n):
    runs = sorted(instructions(rig, d) for _ in range(n))
    return runs[n // 2]


def pass_times(rig, d, n):
    """Each pass's best time of n runs of `rig check --time`, in ms."""
    best = {}
    for _ in range(n):
        p = subprocess.run([rig, "check", "--time", "main.rig"], cwd=d, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("guard: rig check --time failed: %s" % p.stderr[-400:])
        for line in p.stderr.splitlines():
            m = re.match(r"^(.*?)\s+([\d.]+) ms$", line)
            if m:
                name = m.group(1).strip().replace(" ", "_")
                best[name] = min(best.get(name, float("inf")), float(m.group(2)))
    return best


def build(out):
    subprocess.run(["zig", "build", "-j2", "-Doptimize=ReleaseSafe", "-p", out], cwd=ROOT, check=True)
    return os.path.join(out, "bin", "rig")


def read_base():
    base = {}
    for line in open(BASE):
        if line.strip() and not line.startswith("#"):
            k, v = line.split()
            base[k] = float(v)
    return base


def main():
    if sys.platform != "darwin":
        sys.exit("guard: instruction counts come from macOS's /usr/bin/time -l")
    args = sys.argv[1:]
    update = "--update" in args
    rig = args[args.index("--rig") + 1] if "--rig" in args else None
    with tempfile.TemporaryDirectory() as tmp:
        rig = os.path.abspath(rig) if rig else build(os.path.join(tmp, "build"))
        work = write(os.path.join(tmp, "workload"), gen.workload())
        now = {"instructions": median_instructions(rig, work, 5)}
        load = os.getloadavg()[0]
        timed = update or load < LOAD_LIMIT
        if timed:
            for k, v in pass_times(rig, work, 7).items():
                now["ms." + k] = v
        exps = {}
        for name, n in SCALING.items():
            fixed = median_instructions(rig, write(os.path.join(tmp, "%s_1" % name), gen.program(name, 1)), 3)
            small = median_instructions(rig, write(os.path.join(tmp, "%s_%d" % (name, n)), gen.program(name, n)), 3) - fixed
            large = median_instructions(rig, write(os.path.join(tmp, "%s_%d" % (name, 8 * n)), gen.program(name, 8 * n)), 3) - fixed
            exps[name] = math.log(max(large, 1) / max(small, 1)) / math.log(8)

    bad = 0
    for name, e in exps.items():
        flag = "  TOO STEEP" if e > EXP_LIMIT else ""
        bad += bool(flag)
        print("scaling %-9s n to 8n: exponent %.2f (limit %.2f)%s" % (name, e, EXP_LIMIT, flag))
    if update:
        if bad:
            sys.exit("guard: not updating the baseline while a scaling pair fails")
        with open(BASE, "w") as w:
            w.write("# rig check of bench/check/gen.py's workload, ReleaseSafe; bench/check/guard.py --update writes it\n")
            w.write("# instructions: median of 5; ms.PASS: best of 7 of `rig check --time`, on the Mac\n")
            for k, v in now.items():
                w.write("%s %s\n" % (k, int(v) if k == "instructions" else "%.3f" % v))
        print("guard: wrote %s" % os.path.relpath(BASE, ROOT))
        return
    base = read_base()
    ratio = now["instructions"] / base["instructions"]
    flag = "  REGRESSION" if ratio > INSTR_LIMIT else ""
    bad += bool(flag)
    print("instructions %d (baseline %d, %.1f%% %s)%s" % (now["instructions"], base["instructions"], abs(ratio - 1) * 100, "more" if ratio >= 1 else "fewer", flag))
    if not timed:
        print("passes: skipped, load %.1f is %.0f or more" % (load, LOAD_LIMIT))
    else:
        for k, b in base.items():
            if not k.startswith("ms."):
                continue
            v = now.get(k)
            if v is None:
                print("%-16s missing from rig check --time  REGRESSION" % k[3:])
                bad += 1
                continue
            slow = v > b * PASS_LIMIT and v - b > PASS_FLOOR_MS
            bad += slow
            print("%-16s %8.3f ms (baseline %.3f)%s" % (k[3:], v, b, "  REGRESSION" if slow else ""))
    sys.exit(1 if bad else 0)


main()
