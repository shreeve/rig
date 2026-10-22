import os, random, re, shutil, subprocess, sys, hashlib
S = os.path.dirname(os.path.abspath(__file__))
RIG = "/Users/shreeve/Data/Code/rig/bin/rig"
ROOT = "/Users/shreeve/Data/Code/rig/test"
dirs = []
for area in ("behavior/modules", "reject/modules"):
    for d in sorted(os.listdir(os.path.join(ROOT, area))):
        p = os.path.join(ROOT, area, d)
        if os.path.isdir(p) and any(k in d for k in ("generic", "foreign", "const_generics", "public_surface", "self_nesting")):
            dirs.append(p)
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
n = int(sys.argv[2]) if len(sys.argv) > 2 else 300
run_accepted = len(sys.argv) > 3
random.seed(seed)
TOK = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+|\S")
out = os.path.join(S, "fuzzout"); os.makedirs(out, exist_ok=True)
bad = []
seen = set()
stats = {"acc": 0, "rej": 0}
for i in range(n):
    src = random.choice(dirs)
    work = os.path.join(S, "fz", f"w{seed}")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(src, work)
    files = [f for f in os.listdir(work) if f.endswith(".rig")]
    texts = {f: open(os.path.join(work, f)).read() for f in files}
    names = sorted(set(t for x in texts.values() for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", x)))
    for _ in range(random.randint(1, 3)):
        f = random.choice(files)
        t = texts[f]
        toks = [(m.start(), m.end()) for m in TOK.finditer(t)]
        if not toks: continue
        s, e = random.choice(toks)
        op = random.randrange(8)
        if op == 0: r = ""                       # delete token
        elif op == 1: r = random.choice(["[", "]", ".", "(", ")", ",", "[Int]", "[Int, 3]", ".x", "?", "!", "*"]) + t[s:e]
        elif op == 2: r = t[s:e] + random.choice(["[", "]", ".", "[Int]", "[T]", "[3]", ".Wrap", ".max", "[lib.Wrap[Int]]", "?", "[]"])
        elif op == 3: r = random.choice(names)
        elif op == 4: r = random.choice(["lib", "util", "Int", "T", "U", "n", "Self", "self", "Vec", "Wrap", "Pair", "Box", "none", "pub"])
        elif op == 5: r = random.choice(["lib.", "util.", "lib.Wrap[", "lib.max["]) + t[s:e]
        elif op == 6:
            # swap with another token
            s2, e2 = random.choice(toks)
            if s2 < s: s, e, s2, e2 = s2, e2, s, e
            if e > s2: continue
            t = t[:s] + t[s2:e2] + t[e:s2] + t[s:e] + t[e2:]
            texts[f] = t; continue
        else:
            # toggle pub
            r = ("pub " + t[s:e]) if t[s:e] in ("fun", "struct", "enum", "sub", "type") else t[s:e].replace("pub", "")
        texts[f] = t[:s] + r + t[e:]
    h = hashlib.md5(repr(sorted(texts.items())).encode()).hexdigest()
    if h in seen: continue
    seen.add(h)
    for f, t in texts.items(): open(os.path.join(work, f), "w").write(t)
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(S, "out", f"fz{seed}"))
    try:
        p = subprocess.run(["gtimeout", "10", RIG, "check", "main.rig"], cwd=work, capture_output=True, text=True, env=env)
        rc, o = p.returncode, p.stdout + p.stderr
    except Exception as ex:
        rc, o = -1, str(ex)
    why = None
    if rc not in (0, 1): why = f"rc={rc}"
    elif re.search(r"panic|unreachable|Segmentation|thread \d+|error: .*@compileError|integer overflow|index out of bounds", o): why = "crashlike"
    elif rc == 1 and not re.search(r"^\S+\.rig:\d+:\d+: error:", o, re.M) and "error:" in o and not o.startswith("error:"): why = "no-loc"
    elif rc == 1 and not re.search(r"\.rig:\d+:\d+: error:|^error:", o, re.M): why = "no-diag"
    if rc == 0:
        stats["acc"] += 1
        if run_accepted:
            p2 = subprocess.run(["gtimeout", "120", RIG, "run", "main.rig"], cwd=work, capture_output=True, text=True, env=env)
            o2 = p2.stdout + p2.stderr
            if p2.returncode != 0 and ("error:" in o2 and ".zig:" in o2 or "leak" in o2.lower() or p2.returncode not in (0,1)):
                why = f"accepted-but-run-failed rc={p2.returncode}"; o = o2
    else:
        stats["rej"] += 1
    if why:
        dst = os.path.join(out, f"s{seed}_{i}")
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(work, dst)
        open(os.path.join(dst, "OUTPUT.txt"), "w").write(f"{why}\nsrc={src}\n{o}")
        bad.append((dst, why))
        print("BAD", dst, why, flush=True)
print("done", seed, len(seen), stats, len(bad))
