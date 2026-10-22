#!/usr/bin/env python3
"""Mutation / token-soup fuzz of `rig check`: look for crashes, hangs, and
diagnostics without a position. Accepted mutants are saved for a run pass."""
import glob, os, random, re, subprocess, sys, hashlib, json
from multiprocessing import Pool

RIG = "/Users/shreeve/Data/Code/rig/bin/rig"
ROOT = "/Users/shreeve/Data/Code/rig"
OUT = sys.argv[1]
N = int(sys.argv[2])
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 0
DIAG = re.compile(r"\.rig:\d+:\d+: error:")
CRASH = re.compile(r"^thread \d+ panic|^panic:|internal error|reached unreachable code|Segmentation fault|integer overflow|index out of bounds", re.M)

TOKENS = ["<", ">", "?", "!", "+", "-", "*", "~", "|", "||", "(", ")", "[", "]", ".", "..", ",", ":",
          "=", "=!", "==", "!=", "<=", ">=", "=>", "->", "??", "+%", "-%", "*%", "<<", ">>", "&", "^",
          "%", "/", "\\", "#", "@", "\"", "'", "0", "1", "255", "0x", "1e", ".5", "1_0", "none", "true",
          "and", "or", "not", "if", "else", "for", "in", "while", "match", "break", "continue", "return",
          "fun", "sub", "struct", "enum", "error", "type", "use", "pub", "raw", "extern", "defer", "errdefer",
          "catch", "as", "new", "drop", "test", "zig", "of", "self", "Self", "Int", "U8", "String", "Vec",
          "Cell", "Box", "Signal", "x", "y", "_", "main", "print", "\n", "\n  ", "\n    ", "  ", "\t", " ",
          "@sizeOf", "@intCast", "[3 of 0]", "Vec[Int]()", "*|x| x", "|+a| a", ":outer", "\"\\u{", "\"\\x4",
          "U128.max", "I8.min", "-", "<x", "!x", "?x", "+x", "-x", "*x", "~x", "x!", "x?", "x?.y", "é", "\x00"]


def corpus():
    files = []
    for pat in ["test/**/*.rig", "examples/*.rig"]:
        files += glob.glob(os.path.join(ROOT, pat), recursive=True)
    srcs = []
    for f in files:
        try:
            srcs.append(open(f, encoding="utf8").read())
        except Exception:
            pass
    # doc blocks
    for md in glob.glob(os.path.join(ROOT, "*.md")) + glob.glob(os.path.join(ROOT, "docs/*.md")):
        t = open(md, encoding="utf8").read()
        for m in re.finditer(r"```rig[^\n]*\n(.*?)```", t, re.S):
            srcs.append(m.group(1))
    extra = glob.glob(os.path.join(os.path.dirname(OUT), "c", "*", "*", "main.rig"))
    random.Random(1).shuffle(extra)
    for f in extra[:int(os.environ.get('NEXTRA', '300'))]:
        srcs.append(open(f).read())
    return srcs


def mutate(r, src, srcs):
    lines = src.split("\n")
    for _ in range(r.choice([1, 1, 1, 2, 2, 3])):
        c = r.random()
        if not lines:
            lines = [""]
        i = r.randrange(len(lines))
        if c < 0.15:
            del lines[i]
        elif c < 0.25:
            lines.insert(i, lines[r.randrange(len(lines))])
        elif c < 0.35:
            j = r.randrange(len(lines))
            lines[i], lines[j] = lines[j], lines[i]
        elif c < 0.5:
            l = lines[i]
            p = r.randint(0, len(l))
            lines[i] = l[:p] + r.choice(TOKENS) + l[p:]
        elif c < 0.6:
            l = lines[i]
            if l:
                p = r.randrange(len(l))
                q = min(len(l), p + r.randint(1, 5))
                lines[i] = l[:p] + l[q:]
        elif c < 0.68:
            # change indentation
            l = lines[i]
            st = l.lstrip(" ")
            ind = len(l) - len(st)
            lines[i] = " " * max(0, ind + r.choice([-2, 2, -1, 1, 4])) + st
        elif c < 0.78:
            # splice a line from another program
            o = r.choice(srcs).split("\n")
            lines.insert(i, r.choice(o))
        elif c < 0.85:
            # replace an identifier with another from the file
            ids = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", src)
            if ids:
                a, b = r.choice(ids), r.choice(ids)
                lines[i] = re.sub(r"\b%s\b" % re.escape(a), b, lines[i])
        elif c < 0.9:
            # sigil swap
            l = lines[i]
            sig = "<?!+-*~"
            ps = [p for p, ch in enumerate(l) if ch in sig]
            if ps:
                p = r.choice(ps)
                lines[i] = l[:p] + r.choice(sig) + l[p + 1:]
        elif c < 0.95:
            # number swap
            lines[i] = re.sub(r"\b\d+\b", lambda m: r.choice(["0", "-1", "255", "256", "9223372036854775807",
                                                              "9223372036854775808", "340282366920938463463374607431768211456",
                                                              "128", "-129", "1e308", "0x7f"]), lines[i], count=1)
        else:
            # truncate
            lines = lines[: i + 1]
            if lines:
                l = lines[-1]
                lines[-1] = l[: r.randint(0, len(l))]
    return "\n".join(lines)


def soup(r):
    toks = [r.choice(TOKENS) for _ in range(r.randint(1, 60))]
    return "".join(t if r.random() < 0.5 else t + " " for t in toks)


def job(args):
    idx, src = args
    d = os.path.join(OUT, "w%d" % (idx % 16))
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "m%d.rig" % idx)
    with open(f, "w", encoding="utf8", errors="surrogateescape") as fh:
        fh.write(src)
    try:
        p = subprocess.run([RIG, "check", f], capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        keep(idx, src, "HANG", "")
        return "HANG"
    err = p.stderr.decode("utf8", "replace")
    rc = p.returncode
    res = None
    if rc < 0 or rc > 1 and rc != 0:
        res = "CRASH_rc%d" % rc
    elif CRASH.search(err):
        res = "CRASH_msg"
    elif rc != 0 and not DIAG.search(err):
        res = "NO_POS"
    elif rc == 0:
        res = "accepted"
        keep(idx, src, "accepted", "")
    else:
        res = "rejected"
    if res not in ("accepted", "rejected"):
        keep(idx, src, res, err)
    os.unlink(f)
    return res


def keep(idx, src, kind, err):
    d = os.path.join(OUT, kind)
    os.makedirs(d, exist_ok=True)
    h = hashlib.md5(src.encode("utf8", "surrogateescape")).hexdigest()[:10]
    open(os.path.join(d, h + ".rig"), "w", encoding="utf8", errors="surrogateescape").write(src)
    if err:
        open(os.path.join(d, h + ".err"), "w").write(err[-4000:])


if __name__ == "__main__":
    srcs = corpus()
    r = random.Random(SEED)
    work = []
    for i in range(N):
        if r.random() < 0.1:
            work.append((i, soup(r)))
        else:
            work.append((i, mutate(r, r.choice(srcs), srcs)))
    from collections import Counter
    c = Counter()
    with Pool(10) as p:
        for k, res in enumerate(p.imap_unordered(job, work, chunksize=20)):
            c[res] += 1
            if k % 2000 == 0:
                print(k, dict(c), flush=True)
    print("DONE", dict(c))
