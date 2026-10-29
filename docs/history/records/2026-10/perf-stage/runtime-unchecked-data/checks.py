#!/usr/bin/env python3
"""checks.py BIN DIS IPS... : the executed cost of Zig's own safety checks,
by the innermost runtime source line that wrote them.

A check is a conditional jump that leads to a call of one of Zig's panic
handlers (debug.FullPanic.*): its target, or the instruction after it,
reaches such a call in a few straight-line instructions or a jmp. Its
cost is the samples at the jump and at a cmp/test just before it. Each
check jump is attributed (addr2line -i) to its innermost frame in
rig/{runtime,alloc,table,sched,tasks,net}.zig, else to 'user'."""
import sys, re, subprocess, collections
binp, disp = sys.argv[1:3]; ipsps = sys.argv[3:]
INS = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
addrs = []; ins = {}
for l in open(disp):
    m = INS.match(l)
    if not m: continue
    a = int(m.group(1), 16); addrs.append(a); ins[a] = (m.group(2), m.group(3))
nxt = {addrs[i]: addrs[i + 1] for i in range(len(addrs) - 1)}
prv = {addrs[i + 1]: addrs[i] for i in range(len(addrs) - 1)}
def target(op):
    m = re.match(r"([0-9a-f]+) <", op); return int(m.group(1), 16) if m else None
memo = {}
def panics(a, depth=0):
    """a reaches a call of a Zig panic handler straight-line (<= 8 instructions, jmps followed)."""
    if a in memo: return memo[a]
    r = False; x = a
    for _ in range(8):
        if x not in ins: break
        mn, op = ins[x]
        if mn == "call":
            r = "debug.FullPanic" in op; break
        if mn == "jmp":
            t = target(op); r = t is not None and depth < 3 and panics(t, depth + 1); break
        if mn.startswith("j") or mn.startswith("ret") or mn == "ud2": break
        x = nxt.get(x)
        if x is None: break
    memo[a] = r; return r
checks = set()
for a in addrs:
    mn, op = ins[a]
    if mn.startswith("j") and mn != "jmp":
        t = target(op)
        if (t is not None and panics(t)) or (a in nxt and panics(nxt[a])): checks.add(a)
cost = collections.Counter()  # check jump -> samples
if ipsps == ["static"]:
    for a in checks: cost[a] = 1
    ipsps = []
for p in ipsps:
    for l in open(p):
        n, ip = l.split(); ip = int(ip, 16); n = int(n)
        if ip in checks: cost[ip] += n
        elif ip in nxt and nxt[ip] in checks and ins[ip][0] in ("cmp", "test"): cost[nxt[ip]] += n
tot = sum(int(l.split()[0]) for p in ipsps for l in open(p)) or len(checks)
hot = [a for a in cost]
p = subprocess.run(["addr2line", "-i", "-f", "-C", "-a", "-e", binp], input="\n".join(hex(a) for a in hot) + "\n", capture_output=True, text=True)
frames = {}; cur = None; L = p.stdout.split("\n"); i = 0
while i < len(L):
    if L[i].startswith("0x"): cur = int(L[i], 16); frames[cur] = []; i += 1; continue
    if cur is not None and i + 1 < len(L): frames[cur].append((L[i], L[i + 1])); i += 2; continue
    i += 1
RT = re.compile(r"/rig/(runtime|alloc|table|sched|tasks|net)\.zig:(\d+)")
STD = re.compile(r"/std/(.*\.zig):(\d+)")
by = collections.Counter(); kinds = collections.defaultdict(collections.Counter)
for a, n in cost.items():
    key = "user"; via = ""
    fr = frames.get(a, [])
    for j, (fn, loc) in enumerate(fr):
        m = RT.search(loc)
        if m:
            key = f"{m.group(1)}.zig:{m.group(2)} {fn.split('(')[0]}"
            if j > 0:
                s = STD.search(fr[0][1]); via = f" via {s.group(1)}:{s.group(2)}" if s else ""
            break
    by[key + via] += n
print(f"# samples {tot}; in Zig checks {sum(cost.values())} ({100*sum(cost.values())/tot:.2f}%); check jumps {len(checks)}")
rtsum = sum(n for k, n in by.items() if k != "user")
print(f"# in the runtime's Zig: {rtsum} ({100*rtsum/tot:.2f}% of samples)")
for k, n in by.most_common(60): print(f"{n:6d} {100*n/tot:5.2f}% {k}")
