#!/usr/bin/env python3
"""The print-size guard: the machine code one `print` adds to a program
built with `--release=fast`, against the bound in bench/print/guard.txt.

It builds two programs that differ only in how many print lines they add
to one that prints every value, 0 and SITES (200), each line a mix of literal text and values of every
kind print writes (Int, Float, Bool, U8, String, List, object, optional,
enum). The code a site adds is the growth of the executable's text section
(`__text` on macOS, `.text` on Linux) divided by SITES. More than the
bound fails. Both programs run, and every line they print is checked.

Each print is straight-line code: its runs of text written once and each
value by the one writer of its type (`rig.print` in src/runtime.zig). A
change that makes Zig compile print's code again at each site shows here.

usage: cpuq run --cores 2 --label rig:print-size -- bench/print/guard.py [--update] [--rig PATH] [--sites N]

--update writes the measured bytes per site, plus 25%, as the new bound;
commit it with the change that moved it. The bound is measured on the Mac
(arm64): code for another machine has another size. Without --rig it uses
bin/rig.
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BASE = os.path.join(HERE, "guard.txt")
SITES = 200
HEADROOM = 1.25

HEAD = """obj P
  x: Int
  name: String

enum C
  red
  green

sub show(i: Int, s: ?String, xs: ?List[Int], p: ?P, o: Int?)
  f = Float(i) / 4.0
  t = i > 1
  c = C.red if t else C.green
  u: U8 = U8(i)
  print("all", i, f, t, s, xs, p, o, c, u)
"""

TAIL = """
sub main()
  xs: List[Int] = List()
  for i in 0..3
    !xs.push(i)
    p = P(x: i, name: String("n", i))
    s = String("s", i)
    o: Int? = none if i == 1 else i
    show(i, s, xs, p, o)
"""

VALUES = ["i", "f", "t", "s", "xs", "p", "o", "c", "u", "i + 1"]


def site(k):
    """Print line k: a label, then 1 to 5 values, some with text between."""
    parts = ['"s%d"' % k]
    for j in range(1 + k % 5):
        if (k + j) % 3 == 0:
            parts.append('"v%d="' % j)
        parts.append(VALUES[(k * 3 + j) % len(VALUES)])
    return "  print(%s)\n" % ", ".join(parts)


def program(n):
    return HEAD + "".join(site(k) for k in range(n)) + TAIL


def text_bytes(exe):
    """The size of the executable's code section."""
    if sys.platform == "darwin":
        out = subprocess.run(["size", "-m", exe], capture_output=True, text=True, check=True).stdout
        m = re.search(r"Section __text: (\d+)", out)
    else:
        out = subprocess.run(["size", "-A", exe], capture_output=True, text=True, check=True).stdout
        m = re.search(r"^\.text\s+(\d+)", out, re.M)
    if not m:
        sys.exit("guard: no text section in `size` of %s:\n%s" % (exe, out))
    return int(m.group(1))


def build(rig, d, n):
    src = os.path.join(d, "p%d.rig" % n)
    exe = os.path.join(d, "p%d" % n)
    with open(src, "w") as f:
        f.write(program(n))
    p = subprocess.run([rig, "build", "--release=fast", "-o", exe, src], cwd=d, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("guard: rig build of %d sites failed:\n%s" % (n, p.stderr[-2000:]))
    out = subprocess.run([exe], capture_output=True, text=True)
    lines = out.stdout.splitlines()
    want = ["all " if k == 0 else "s%d " % (k - 1) for k in range(n + 1)] * 3
    if out.returncode != 0 or len(lines) != len(want) or any(not l.startswith(w) for l, w in zip(lines, want)):
        sys.exit("guard: the %d-site program printed wrong lines (exit %d):\n%s" % (n, out.returncode, out.stdout[:2000]))
    return text_bytes(exe), os.path.getsize(exe)


def main():
    args = sys.argv[1:]
    update = "--update" in args
    rig = os.path.join(ROOT, "bin", "rig")
    n = SITES
    if "--rig" in args:
        rig = os.path.abspath(args[args.index("--rig") + 1])
    if "--sites" in args:
        n = int(args[args.index("--sites") + 1])
    with tempfile.TemporaryDirectory(prefix="rig-print-size-") as d:
        t0, f0 = build(rig, d, 0)
        tn, fn = build(rig, d, n)
    per_site = (tn - t0) / n
    print("text: %d bytes, and %d with %d more sites; file: %d and %d bytes" % (t0, tn, n, f0, fn))
    print("code per print site: %.0f bytes" % per_site)
    if update:
        with open(BASE, "w") as f:
            f.write("# bench/print/guard.py: the most code one print site may add, --release=fast\n")
            f.write("# measured %.0f bytes per site; the bound is that plus %d%%\n" % (per_site, round((HEADROOM - 1) * 100)))
            f.write("bytes_per_site %d\n" % round(per_site * HEADROOM))
        print("wrote %s" % BASE)
        return
    with open(BASE) as f:
        bound = int(re.search(r"^bytes_per_site (\d+)", f.read(), re.M).group(1))
    if per_site > bound:
        sys.exit("FAIL: a print site adds %.0f bytes of code, above the bound of %d (bench/print/guard.txt)" % (per_site, bound))
    print("ok: within the bound of %d bytes per site" % bound)


if __name__ == "__main__":
    main()
