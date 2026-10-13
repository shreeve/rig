#!/usr/bin/env python3
"""Check std.json against Python's json module on valid and invalid JSON.

usage: test/json/compare.py [-j N] [-v] [--subset] [--tmp DIR] [--groups]
                            [GROUP ...] [--only SUBSTRING]
Run it through `./test/run json`, which also sets up the build store.

Groups (default: all):
  cases     cases.txt: hand-written cases, many from serde_json's
            tests, with exact error kinds and byte offsets
  scan      strings of each length to 33 with a quote, escape, control,
            or non-ASCII byte at the edges of the blocks the scan reads
  edges     3-byte UTF-8 runs, digit runs, and escapes back to back, at
            every alignment of the words the parser reads
  blocks    a quote, escape, control, or byte of 0x80 or more at each offset
            0..130 from where a string scan starts, mid-input and at its end
  spaces    whitespace runs of each length 0..130 wherever the parser skips
            them, ended by a near-whitespace byte or by the end of the input
  floats    generated numbers that stress correct rounding (seeded, so the
            same every run): random doubles, halfway points, boundaries
  checker   data/simd-json/{pass,fail,crash}: JSON_checker and fuzzer inputs
  deep      nesting at and past the depth limit (1024)
  corpus    the benchmark files and simdjson's examples, whole

--subset keeps a fixed, spread-out part of every group (below), so the
default `./test/run` stays fast; every group is still represented.

The checker and corpus groups read third-party files that
tools/fetch-json-data.sh puts in test/json/data/. Without them (or with
a file that differs from its pinned sha256) those groups are skipped,
with a note and exit status 3 when nothing else ran; JSON_REQUIRE_DATA=1
makes that a failure.

The cases become a few Rig programs (driver.rig.tmpl), with every input
embedded as a table of string literals, run under `rig run` with
RIG_SANITIZE=1. The program prints a canonical dump of each parse, which
is compared with one computed from Python's json module (README.md).
Exit status 0 only if every case passes.
Environment: RIG (default bin/rig), JSON (another parser than std/json.rig,
such as an experiment), JSON_REQUIRE_DATA.
"""
import argparse, decimal, hashlib, json, math, os, random, shutil, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RIG = os.environ.get("RIG", os.path.join(ROOT, "bin", "rig"))
DATA = os.path.join(HERE, "data")
FETCH = os.path.join(ROOT, "tools", "fetch-json-data.sh")
MAX_DEPTH = 1024
# The most bytes of literal text in one program: the inputs as escaped,
# under Rig's 16 MiB limit on a source file with room for the driver.
BATCH_BYTES = 8 * 1024 * 1024
BATCH_CASES = 6000

sys.set_int_max_str_digits(0)
sys.setrecursionlimit(20000)

# ---- The reference ---------------------------------------------------

class Reject(Exception):
    pass

class Obj(list):
    pass

def reject(_):
    raise Reject()

def to_float(s):
    f = float(s)
    if math.isinf(f):
        raise Reject()
    return f

def to_int(s):
    if s == "-0":
        return -0.0
    n = int(s)
    if -2 ** 63 <= n < 2 ** 63:
        return n
    try:
        return to_float(n)
    except OverflowError:
        raise Reject()

def depth(data):
    d = m = 0
    in_str = esc = False
    for b in data:
        if in_str:
            if esc: esc = False
            elif b == 0x5C: esc = True
            elif b == 0x22: in_str = False
        elif b == 0x22: in_str = True
        elif b in (0x5B, 0x7B): d += 1; m = max(m, d)
        elif b in (0x5D, 0x7D): d -= 1
    return m

def dump_string(s, lines):
    if any(0xD800 <= ord(c) <= 0xDFFF for c in s):
        raise Reject()  # a lone surrogate from a \u escape
    raw = s.encode("utf-8")
    out = bytearray(b"s ")
    for b in raw:
        if b == 0x5C: out += b"\\\\"
        elif b < 0x20 or b == 0x7F: out += b"\\x%02x" % b
        else: out.append(b)
    lines.append(out.decode("utf-8"))

def walk(v, lines):
    if v is None: lines.append("null")
    elif v is True: lines.append("true")
    elif v is False: lines.append("false")
    elif isinstance(v, int): lines.append("i %d" % v)
    elif isinstance(v, float): lines.append("f %d" % struct.unpack("<Q", struct.pack("<d", v))[0])
    elif isinstance(v, str): dump_string(v, lines)
    elif isinstance(v, Obj):
        lines.append("{")
        for k, x in v:
            dump_string(k, lines)
            walk(x, lines)
        lines.append("}")
    else:
        lines.append("[")
        for x in v: walk(x, lines)
        lines.append("]")

def reference(data):
    """The canonical dump of `data`, or None when it is not valid JSON."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if depth(data) > MAX_DEPTH:
        return None
    try:
        v = json.loads(text, parse_int=to_int, parse_float=to_float,
                       parse_constant=reject, object_pairs_hook=Obj)
        lines = []
        walk(v, lines)
        return lines
    except (ValueError, Reject, RecursionError):
        return None

# ---- Cases -----------------------------------------------------------

def unescape(s):
    return s.encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1")

def cases_group():
    out = []
    for line in open(os.path.join(HERE, "cases.txt"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"): continue
        name, src, want = line.split("\t")
        data = unescape(src)
        out.append((name, data, None if want == "ok" else want))
    return out

def float_group():
    rnd = random.Random(20261010)
    decimal.getcontext().prec = 1200
    xs = []
    while len(xs) < 2000:
        f = struct.unpack("<d", struct.pack("<Q", rnd.getrandbits(64)))[0]
        if math.isfinite(f): xs.append(f)
    for _ in range(500):  # subnormals and values near 1
        xs.append(struct.unpack("<d", struct.pack("<Q", rnd.getrandbits(52)))[0])
        xs.append(rnd.uniform(-1000, 1000))
    sets = {}
    sets["shortest"] = [repr(f) for f in xs]
    sets["e17"] = ["%.17e" % f for f in xs]
    sets["e16"] = ["%.16e" % f for f in xs]
    sets["g15"] = ["%.15g" % f for f in xs]
    half, near = [], []
    for f in xs[:1500]:
        g = math.nextafter(f, math.inf)
        if not math.isfinite(g): continue
        mid = (decimal.Decimal(f) + decimal.Decimal(g)) / 2
        half.append(format(mid, "e"))
        digits, exp = mid.as_tuple().digits, mid.as_tuple().exponent
        sign = "-" if mid < 0 else ""
        lead = "".join(map(str, digits))
        for k in (17, 18, 19):
            if len(lead) > k:
                cut = lead[:k]
                for bump in (0, 1):
                    t = str(int(cut) + bump)
                    e = exp + len(lead) - k
                    near.append("%s%se%d" % (sign, t, e))
    sets["halfway"] = half
    sets["near-halfway"] = near
    dec = []
    for _ in range(3000):
        nd = rnd.randint(1, 19)
        m = rnd.randint(10 ** (nd - 1), 10 ** nd - 1)
        e = rnd.randint(-345, 310)
        dec.append("%d%s%d" % (m, rnd.choice("eE"), e))
        i = rnd.randint(0, nd)
        s = str(m)
        dec.append(("-" if rnd.random() < 0.3 else "") + (s[:i] or "0") + "." + (s[i:] or "0"))
    sets["decimal"] = dec
    sets["pow10"] = ["1e%d" % k for k in range(-350, 309)] + ["9.99999999999999999e%d" % k for k in range(-330, 308)]
    ints = [str(rnd.randint(-2 ** 63, 2 ** 63 - 1)) for _ in range(2000)]
    ints += [str(rnd.randint(2 ** 63, 2 ** 70)) for _ in range(200)]
    ints += [str(2 ** k + d) for k in range(50, 64) for d in (-1, 0, 1)]
    sets["ints"] = ints
    out = []
    for name, nums in sets.items():
        for i in range(0, len(nums), 400):
            text = "[" + ", ".join(nums[i:i + 400]) + "]"
            out.append(("floats-%s-%d" % (name, i // 400), text.encode(), None))
    return out

def files_group(paths, prefix):
    out = []
    for p in paths:
        with open(p, "rb") as f:
            out.append((prefix + os.path.splitext(os.path.basename(p))[0], f.read(), None))
    return out

def pinned(directory):
    """The files tools/fetch-json-data.sh pins directly in `directory`
    under data/, in order: the groups read these and no others."""
    return sorted(os.path.join(DATA, rel) for _, rel in manifest() if os.path.dirname(rel) == directory)

def checker_group():
    return (files_group(pinned("simd-json/pass"), "pass-") +
            files_group(pinned("simd-json/fail"), "fail-") +
            files_group(pinned("simd-json/crash"), "crash-"))

def deep_group():
    out = []
    for n in (MAX_DEPTH - 1, MAX_DEPTH):
        out.append(("deep-array-%d" % n, b"[" * n + b"]" * n, None))
        out.append(("deep-object-%d" % n, b'{"a":' * n + b"1" + b"}" * n, None))
    out.append(("deep-array-%d" % (MAX_DEPTH + 1), b"[" * (MAX_DEPTH + 1) + b"]" * (MAX_DEPTH + 1), "error depth %d" % MAX_DEPTH))
    out.append(("deep-mixed-over", b'[{"a":' * 600 + b"1" + b"}]" * 600, "error depth %d" % (6 * 512)))
    out.append(("deep-unclosed", b"[" * 100000, "error depth %d" % MAX_DEPTH))
    return out

def corpus_group():
    return files_group(pinned("simd-json"), "corpus-") + files_group(pinned("simdjson"), "example-")

def scan_group():
    """Strings of every length up to 33 with a special byte at chosen
    positions, at two alignments: the edges of the 8- and 16-byte blocks
    the string scan reads."""
    out = []
    for pad in (0, 3):
        lead = b" " * pad
        valid = []
        for n in range(34):
            valid.append(b'"' + b"a" * n + b'"')
            for k in sorted({0, 1, 7, 8, 9, 15, 16, 17, n - 1}):
                if not 0 <= k < n: continue
                a, b = b"a" * k, b"a" * (n - k - 1)
                valid.append(b'"' + a + b"\\n" + b + b'"')
                valid.append(b'"' + a + b"\xc3\xa9" + b + b'"')
                valid.append(b'"' + a + b"\xe2\x82\xac\xe2\x82\xac" + b + b'"')
                valid.append(b'"' + a + b"\x7f" + b + b'"')
                out.append(("scan-ctrl-%d-%d-%d" % (pad, n, k), lead + b'"' + a + b"\x1f" + b + b'"', "error control %d" % (pad + 1 + k)))
                out.append(("scan-utf8-%d-%d-%d" % (pad, n, k), lead + b'"' + a + b"\xff" + b + b'"', "error utf8 %d" % (pad + 1 + k)))
                out.append(("scan-eof-%d-%d-%d" % (pad, n, k), lead + b'"' + a + b"a" + b, "error eof %d" % (pad + 1 + n)))
        out.append(("scan-valid-%d" % pad, lead + b"[" + b",".join(valid) + b"]", None))
    return out

def edges_group():
    """The other word-at-a-time paths, at every alignment: runs of 3-byte
    UTF-8 with another sequence (valid or not) at each place in the run,
    digit runs of every length to 25 (the SWAR digit reads), and escapes
    back to back, with a bad hex digit at each place."""
    out = []
    three = [b"\xe4\xb8\xad", b"\xe3\x82\xa2", b"\xef\xbf\xbf"]
    others = {"e0": (b"\xe0\xa0\x80", None), "ed": (b"\xed\x9f\xbf", None), "c3": (b"\xc3\xa9", None),
              "f0": (b"\xf0\x9f\x98\x80", None), "a": (b"a", None),
              "sur": (b"\xed\xa0\x80", "utf8"), "over": (b"\xe0\x80\x80", "utf8"), "cut": (b"\xe4\xb8", "utf8"),
              "bad2": (b"\xe4\x41\xad", "utf8"), "bad3": (b"\xe4\xb8\x41", "utf8"), "cont": (b"\xb8", "utf8"),
              "f4": (b"\xf4\x90\x80\x80", "utf8")}
    for pad in range(8):
        lead = b" " * pad
        valid = []
        for n in range(13):
            run = b"".join(three[k % 3] for k in range(n))
            valid.append(b'"' + run + b'"')
            valid += [b'"' + run + seq + run + b'"' for seq, err in others.values() if err is None]
            out.append(("edge-utf8-eof-%d-%d" % (pad, n), lead + b'"' + run, "error eof %d" % (pad + 1 + len(run))))
            for k in range(n + 1 if n <= 8 else 0):
                a = b"".join(three[j % 3] for j in range(k))
                b = b"".join(three[j % 3] for j in range(k, n))
                for name, (seq, err) in others.items():
                    s = b'"' + a + seq + b + b'"'
                    if err is None:
                        valid.append(s)
                    else:
                        out.append(("edge-utf8-%s-%d-%d-%d" % (name, pad, n, k), lead + s, "error utf8 %d" % (pad + 1 + len(a))))
        out.append(("edge-utf8-valid-%d" % pad, lead + b"[" + b",".join(valid) + b"]", None))
        nums = []
        for n in range(1, 26):
            digits = b"".join(b"%d" % ((k * 7 + 3) % 10) for k in range(n))
            i = b"1" + digits[1:]
            nums += [i, b"-" + i, b"0." + digits, b"1." + digits, i + b"." + digits[:3], i + b"e" + digits[:3], b"9" * n]
            out.append(("edge-int-end-%d-%d" % (pad, n), lead + i, None))
            out.append(("edge-frac-end-%d-%d" % (pad, n), lead + b"0." + digits, None))
            out.append(("edge-int-%d-%d-slash" % (pad, n), lead + b"[" + i + b"/]", "error unexpected %d" % (pad + 1 + n)))
            out.append(("edge-int-%d-%d-colon" % (pad, n), lead + b"[" + i + b":]", "error unexpected %d" % (pad + 1 + n)))
            out.append(("edge-int-%d-%d-high" % (pad, n), lead + b"[" + i + b"\xb0]", "error unexpected %d" % (pad + 1 + n)))
            out.append(("edge-frac-%d-%d-slash" % (pad, n), lead + b"[0." + digits + b"/]", "error unexpected %d" % (pad + 3 + n)))
        out.append(("edge-num-valid-%d" % pad, lead + b"[" + b",".join(nums) + b"]", None))
        escs = [b"\\n", b"\\u00e9", b"\\u4E2D", b"\\ud83d\\ude00", b"\\\\", b"\\u0041", b"\\/"]
        strs = []
        for n in range(1, 12):
            run = b"".join(escs[k % len(escs)] for k in range(n))
            strs += [b'"' + run + b'"', b'"x' + run + b'y"', b'"' + run + b"z" + run + b'"']
            out.append(("edge-esc-eof-%d-%d" % (pad, n), lead + b'"' + run, "error eof %d" % (pad + 1 + len(run))))
        out.append(("edge-esc-valid-%d" % pad, lead + b"[" + b",".join(strs) + b"]", None))
        for k in range(4):
            pre = b'"\\u4e2d\\n\\u00e9'
            for bad in b"/:@G`g\xb0":
                hexs = bytearray(b"4e2d")
                hexs[k] = bad
                s = pre + b"\\u" + bytes(hexs) + b'"'
                out.append(("edge-hex-%d-%d-%02x" % (pad, k, bad), lead + s, "error escape %d" % (pad + len(pre) + 2 + k)))
            cut = pre + b"\\u" + b"4e2d"[:k]
            out.append(("edge-hex-eof-%d-%d" % (pad, k), lead + cut, "error eof %d" % (pad + len(cut))))
    return out

# Where a scan stops, at every offset from where it starts to past two
# 64-byte blocks: a 16-byte first step, then blocks at 16..79 and 80..143.
OFFSETS = range(131)
# Plain string bytes, among them the neighbors of the ones that stop a
# scan (0x21 and 0x23 of `"`, 0x5B and 0x5D of `\`, 0x20 of the control
# bytes, and 0x7F of the bytes from 0x80), so a mask that marks too much
# fails too.
FILL = b"plain !#[]~\x7f {}:,09AZaz/"

def fill(k):
    return (FILL * (k // len(FILL) + 1))[:k]

def blocks_group():
    """A quote, an escape, a control byte, and valid and invalid bytes of
    0x80 or more at each offset 0..130 from where the string scan starts:
    a string's first byte, just after an escape, and just after a UTF-8
    run. Each stop is tested in the middle of the input, with whole
    blocks after it, and at the end of the input, so the last block is
    partial and the input has no padding."""
    out = []
    ctxs = {"start": b"", "esc": b"\\n", "utf8": b"\xc3\xa9"}
    goods = [b"\\n", b"\\\\", b'\\"', b"\\u00e9", b"\xc3\xa9", b"\xe2\x82\xac", b"\xf0\x9f\x98\x80"]
    ctrls = [b"\x1f", b"\x00", b"\x01", b"\x0a", b"\x09"]
    bads = [b"\xff", b"\x80", b"\xc3p", b"\xe0\x80\x80", b"\xed\xa0\x80"]
    for cname, ctx in ctxs.items():
        valid = []
        for k in OFFSETS:
            head = b'"' + ctx + fill(k)
            at = len(head)  # the offset of the stop, with the quote before the string
            tail = fill((k * 37) % 131) + b'"'
            valid.append(head + b'"')
            valid += [head + g + tail for g in goods]
            name = "blocks-%s-%d-" % (cname, k)
            c, bad = ctrls[k % len(ctrls)], bads[k % len(bads)]
            out.append((name + "end", head + b'"', None))
            out.append((name + "ctrl", head + c + fill(70) + b'"', "error control %d" % at))
            out.append((name + "ctrl-end", head + c, "error control %d" % at))
            out.append((name + "utf8", head + bad + fill(70) + b'"', "error utf8 %d" % at))
            out.append((name + "utf8-end", head + (b"\xc3" if k % 2 else b"\xff"), "error utf8 %d" % at))
            out.append((name + "eof", head, "error eof %d" % at))
            out.append((name + "eof-utf8", head + b"\xc3\xa9", "error eof %d" % (at + 2)))
            out.append((name + "eof-slash", head + b"\\", "error eof %d" % (at + 1)))
            out.append((name + "eof-esc", head + b"\\n", "error eof %d" % (at + 2)))
        out.append(("blocks-%s-valid" % cname, b"[" + b",".join(valid) + b"]", None))
        out.append(("blocks-%s-keys" % cname, b"{" + b",".join(s + b":%d" % i for i, s in enumerate(valid)) + b"}", None))
    return out

WS = {"space": b" ", "lf": b"\n", "tab": b"\t", "cr": b"\r", "mixed": b"\r\n \t  \t \n"}

def ws(kind, n):
    w = WS[kind]
    return (w * (n // len(w) + 1))[:n]

def spaces_group():
    """Whitespace runs of every length 0..130, of each whitespace byte
    and mixed, everywhere the parser skips them; ended by a byte just
    outside the four (0x0B, 0x0C, 0x21, ...) in the middle of the input,
    and by the end of the input."""
    out = []
    stops = [b"\x0b", b"\x0c", b"\x00", b"\x21", b"\x1f", b"\xa0", b"\x08", b"\x0e", b"\x19", b"\x2c"]
    kinds = list(WS)
    for kind in kinds:
        parts = []
        for n in OFFSETS:
            w = ws(kind, n)
            parts.append(w + b"{" + w + b'"k"' + w + b":" + w + b"[" + w + b"1" + w + b"," + w + b'"s"' + w +
                         b"," + w + b"[" + w + b"]" + w + b"," + w + b"{" + w + b"}" + w + b"]" + w + b"}" + w)
        out.append(("spaces-%s-valid" % kind, b"[" + b",".join(parts) + b"]", None))
    for n in OFFSETS:
        kind, stop = kinds[n % len(kinds)], stops[n % len(stops)]
        name = "spaces-%d-" % n
        for k in ("space", "mixed"):
            w = ws(k, n)
            out.append((name + k + "-ends", w + b"1" + w, None))
            out.append((name + k + "-empty", w, "error empty %d" % n))
        w = ws(kind, n)
        out.append((name + "stop", b"[" + w + stop + b"]", "error unexpected %d" % (1 + n)))
        out.append((name + "stop-end", b"1" + w + stop, "error trailing %d" % (1 + n)))
        out.append((name + "colon-eof", b'{"a":' + w, "error eof %d" % (5 + n)))
        out.append((name + "comma-eof", b"[1," + w, "error eof %d" % (3 + n)))
    return out

GROUPS = {"cases": cases_group, "scan": scan_group, "edges": edges_group, "blocks": blocks_group,
          "spaces": spaces_group, "floats": float_group,
          "checker": checker_group, "deep": deep_group, "corpus": corpus_group}

# ---- The Rig program -------------------------------------------------

def rig_literal(data):
    """`data` as the text of one Rig string literal."""
    out = []
    for b in data:
        if b == 0x22: out.append('\\"')
        elif b == 0x5C: out.append("\\\\")
        elif 0x20 <= b < 0x7F: out.append(chr(b))
        else: out.append("\\x%02x" % b)
    return "".join(out)

def program(cases):
    # One table of every case's text, and a loop, so the program's code,
    # and its compile time, do not grow with the number of cases.
    names = "".join('  "%s",\n' % name for name, _, _ in cases)
    texts = "".join('  "%s",\n' % rig_literal(data) for _, data, _ in cases)
    consts = "NAMES = [\n%s]\n\nTEXTS = [\n%s]\n" % (names, texts)
    loop = "  for k in 0..NAMES.len\n    run(NAMES[k], TEXTS[k])\n"
    with open(os.path.join(HERE, "driver.rig.tmpl")) as f:
        return f.read().replace("@CASES@", consts).replace("@MAIN@", loop)

def build_and_run(tag, cases, base=None):
    tmp = tempfile.mkdtemp(prefix="json-" + tag + "-", dir=base)
    try:
        os.mkdir(os.path.join(tmp, "src")); os.mkdir(os.path.join(tmp, "out"))
        main = os.path.join(tmp, "src", "main.rig")
        src = program(cases)
        if os.environ.get("JSON"):  # an experiment: a module beside the driver
            shutil.copy(os.environ["JSON"], os.path.join(tmp, "src", "json.rig"))
            src = src.replace("use std.json", "use json")
        with open(main, "w") as f: f.write(src)
        env = dict(os.environ, RIG_OUT_DIR=os.path.join(tmp, "out"), RIG_SANITIZE="1")
        try:
            p = subprocess.run([RIG, "run", main], capture_output=True, env=env, timeout=3600)
        except subprocess.TimeoutExpired:
            return "", "timeout"
        out = p.stdout.decode("utf-8", "replace")
        if b"sanitizer: mapping limit reached" in p.stderr:
            print("WARN rig: sanitizer: mapping limit reached (%s)" % tag)
        return out, ("" if p.returncode == 0 else "exit %d\n%s" % (p.returncode, p.stderr.decode("utf-8", "replace")[-3000:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def split_sections(out):
    secs, cur = {}, None
    for line in out.split("\n"):
        if line.startswith("=== "):
            cur = line[4:]; secs[cur] = []
        elif cur is not None and line != "":
            secs[cur].append(line)
    return secs

# --subset: every group keeps the cases whose position in the group's
# list is a multiple of its step (a case named like the ones in
# ALWAYS is kept whole, since one holds many inputs), so the part is
# fixed and spread over the group. A file group keeps the files no
# larger than MAX_FILE.
STEPS = {"cases": 1, "scan": 12, "edges": 12, "blocks": 16, "spaces": 8,
         "floats": 8, "checker": 1, "deep": 1, "corpus": 1}
ALWAYS = ("-valid", "-keys")
MAX_FILE = 700000

def thin(group, cases):
    if group == "corpus":
        return [c for c in cases if len(c[1]) <= MAX_FILE]
    step = STEPS[group]
    return [c for i, c in enumerate(cases) if i % step == 0 or c[0].endswith(ALWAYS)]

def manifest():
    """(sha256, path under data/) for every file tools/fetch-json-data.sh pins."""
    out = []
    for line in open(FETCH, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 2 and len(parts[0]) == 64 and all(c in "0123456789abcdef" for c in parts[0]):
            out.append(tuple(parts))
    return out

def data_problem():
    """Why the third-party data cannot be used, or None."""
    if not manifest():
        return "%s pins no file this script can read" % os.path.relpath(FETCH, ROOT)
    for want, rel in manifest():
        p = os.path.join(DATA, rel)
        try:
            with open(p, "rb") as f:
                if hashlib.sha256(f.read()).hexdigest() != want:
                    return "%s differs from its pinned sha256" % rel
        except OSError:
            return "%s is missing" % rel
    return None

NEEDS_DATA = ("checker", "corpus")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=2)
    ap.add_argument("-v", action="store_true", help="list every pass")
    ap.add_argument("--subset", action="store_true", help="a fixed, spread-out part of every group")
    ap.add_argument("--tmp", default=None, help="a directory for the generated programs and their builds")
    ap.add_argument("--list", action="store_true", dest="list_groups", help="list the groups and exit")
    ap.add_argument("--stub", metavar="FILE", help="write the driver with one trivial case to FILE and exit")
    ap.add_argument("--check-data", action="store_true", help="exit 1 and say why if the third-party data cannot be used")
    ap.add_argument("--only", default="", help="cases whose name contains this")
    ap.add_argument("groups", nargs="*")
    a = ap.parse_args()
    if a.list_groups:
        print(" ".join(GROUPS))
        return 0
    if a.stub:
        with open(a.stub, "w") as f: f.write(program([("stub", b"[]", None)]))
        return 0
    if a.check_data:
        why = data_problem()
        if why: print(why)
        return 1 if why else 0
    for g in a.groups:
        if g not in GROUPS:
            sys.exit("no group %s (groups: %s)" % (g, " ".join(GROUPS)))
    groups = a.groups or list(GROUPS)
    if a.tmp:
        os.makedirs(a.tmp, exist_ok=True)
    skipped = []
    if any(g in NEEDS_DATA for g in groups):
        why = data_problem()
        if why:
            skipped = [g for g in groups if g in NEEDS_DATA]
            groups = [g for g in groups if g not in NEEDS_DATA]
            print("SKIP %s: %s; run tools/fetch-json-data.sh" % (" ".join(skipped), why))
            if os.environ.get("JSON_REQUIRE_DATA"):
                print("FAIL the third-party data is required (JSON_REQUIRE_DATA)")
                return 1
    # Each program compiles the parser afresh, which costs more than most
    # groups' cases, so consecutive groups share a program. A program
    # ends where its source would pass Rig's 16 MiB limit on a source
    # file, or at BATCH_CASES cases.
    plan, batch, size, names, seen = {}, [], 0, [], set()
    def flush():
        if batch:
            plan["%s-%d" % ("+".join(dict.fromkeys(names)), len(plan))] = list(batch)
    for g in groups:
        cases = GROUPS[g]()
        if not cases:
            sys.exit("FAIL group %s has no cases" % g)
        if a.subset:
            cases = thin(g, cases)
        for c in cases:
            if a.only not in c[0]: continue
            if c[0] in seen: sys.exit("two cases are named " + c[0])
            seen.add(c[0])
            n = len(rig_literal(c[1]))
            if batch and (size + n > BATCH_BYTES or len(batch) >= BATCH_CASES):
                flush()
                batch, size, names = [], 0, []
            batch.append(c); size += n; names.append(g)
    flush()
    # The programs with the most input take longest: start them first.
    order = sorted(plan, key=lambda g: -sum(len(c[1]) for c in plan[g]))
    with ThreadPoolExecutor(max_workers=a.j) as ex:
        results = dict(zip(order, ex.map(lambda g: build_and_run(g, plan[g], a.tmp), order)))
    passed = failed = 0
    errors = []
    for g, cases in plan.items():
        out, err = results[g]
        if err: errors.append("%s: %s" % (g, err))
        secs = split_sections(out)
        for name, data, want_error in cases:
            got = secs.get(name)
            ref = reference(data)
            if want_error is not None:
                want = [want_error]
                if ref is not None:
                    print("CASE BUG", name, "expects an error, but Python accepts it"); failed += 1; continue
            elif ref is None:
                want = None  # any error
            else:
                want = ref
            ok = got is not None and (got == want if want is not None else len(got) == 1 and got[0].startswith("error "))
            if ok:
                passed += 1
                if a.v: print("PASS", name, (got[0] if got and got[0].startswith("error") else ""))
                continue
            failed += 1
            if got is None:
                print("FAIL", name, "(no output)"); continue
            if want is None:
                print("FAIL", name, "should be rejected; got", got[0] if got else "<nothing>"); continue
            i = 0
            while i < min(len(got), len(want)) and got[i] == want[i]: i += 1
            print("FAIL", name, "at line", i)
            print("   want:", want[i][:200] if i < len(want) else "<end>")
            print("   got: ", got[i][:200] if i < len(got) else "<end>")
    for e in errors: print("ERROR", e)
    print("%d passed, %d failed, %d total%s" % (passed, failed, passed + failed,
          ", skipped " + " ".join(skipped) if skipped else ""))
    if failed or errors: return 1
    return 3 if skipped and not passed else 0

sys.exit(main())
