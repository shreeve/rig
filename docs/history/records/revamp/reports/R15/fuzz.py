import random, subprocess, os, sys
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 300
toks = ["a", "w", "b", "s", "[", "]", "..", "..", "..", "!", "?", "<", "+", "-", "*", "~", "of", "0", "1", "2", "n",
        "(", ")", ",", ".", "read", "write", "copy", "fill", "swap", "U16", "I64", "F32", ".big", ".little", "Endian",
        "len", " ", " ", "=", "[]", "![]Int", "?", "!", "if", "for", "in", "match", "=>", "..=", "x", "3"]
pre = "sub f(s: ![]Int, t: []U8, n: Int)\n  a = [1, 2, 3]\n  b: [4]U8 = [4 of 0]\n"
env = dict(os.environ, RIG_OUT_DIR=os.path.abspath("out"))
bad = 0
for i in range(N):
    k = random.randint(1, 14)
    line = "".join(random.choice(toks) + (" " if random.random() < 0.3 else "") for _ in range(k))
    src = pre + "  " + line + "\n  print(a, b, s, t, n)\nsub main()\n  a0 = [0]\n  b0: [1]U8 = [0]\n  f(!a0[..], ?b0[..], 1)\n"
    p = "fz/c%d.rig" % i
    open(p, "w").write(src)
    try:
        r = subprocess.run(["gtimeout", "10", "/Users/shreeve/Data/Code/rig/bin/rig", "check", p], capture_output=True, text=True, env=env, timeout=15)
        out = r.stdout + r.stderr
        crash = r.returncode not in (0, 1) or "panic" in out or "thread " in out or "unreachable" in out
        nodiag = r.returncode == 1 and ":" not in out
        if crash or nodiag:
            bad += 1
            print("BAD", r.returncode, repr(line)); print(out[:600])
        elif r.returncode == 0:
            acc = globals().setdefault("acc", [0]); acc[0] += 1
            r2 = subprocess.run(["gtimeout", "120", "/Users/shreeve/Data/Code/rig/bin/rig", "run", p], capture_output=True, text=True, env=env)
            o2 = r2.stdout + r2.stderr
            if r2.returncode != 0 and "panic:" not in o2:
                bad += 1; print("ACCEPT-BUT-FAIL", repr(line)); print(o2[:800])
            elif "panic" in o2 and "out of range" not in o2 and "out of bounds" not in o2 and "different lengths" not in o2:
                print("RUNTIME", repr(line), o2[:300])
        else:
            os.remove(p)
    except subprocess.TimeoutExpired:
        bad += 1; print("TIMEOUT", repr(line))
print("done", bad, "accepted", globals().get("acc", [0])[0])
