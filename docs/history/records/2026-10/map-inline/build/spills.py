#!/usr/bin/env python3
"""spills.py BIN PERFDATA RUNS PERIOD: the instructions retired in the
built-in Map's and Set's code (source lines of __rig_std___rig_builtin.zig,
wherever they were inlined), from perf samples of instructions taken every
PERIOD over RUNS runs, by kind: spills (stores to the stack), reloads
(loads from it), pushes and pops, and the rest; in millions per run. Also
the static count of each kind in that code."""
import sys, re, subprocess, collections, bisect
binp, data, runs, period = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
out = subprocess.run(["objdump", "-d", "-l", "--no-show-raw-insn", binp], capture_output=True, text=True).stdout
addrs = []; info = []
src = ""; fn = ""
stack = re.compile(r"\((%rsp|%rbp)\)|\(%rsp,|\(%rbp,")
for line in out.splitlines():
    m = re.match(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
    if m:
        a = int(m.group(1), 16); op = m.group(2); args = m.group(3)
        ours = "__rig_std___rig_builtin" in src
        kind = "other"
        if op.startswith("push"): kind = "push"
        elif op.startswith("pop"): kind = "pop"
        elif op.startswith(("mov", "vmov")) and stack.search(args):
            # AT&T: src, dst. A stack operand last is a store.
            parts = args.split(",")
            kind = "spill" if stack.search(parts[-1]) and not stack.search(",".join(parts[:-1])) else "reload"
        addrs.append(a); info.append((ours, kind, fn))
        continue
    m = re.match(r"^(/\S+|\S+\.zig):(\d+)", line)
    if m: src = m.group(1); continue
    m = re.match(r"^[0-9a-f]+ <(.*)>:$", line)
    if m: fn = m.group(1)
static = collections.Counter(k for o, k, f in info if o)
ips = subprocess.run(["perf", "script", "-i", data, "-F", "ip"], capture_output=True, text=True).stdout.split()
dyn = collections.Counter(); byfn = collections.Counter(); tot = 0
for s in ips:
    ip = int(s, 16); tot += 1
    k = bisect.bisect_right(addrs, ip) - 1
    if k < 0 or addrs[k] != ip: continue
    o, kind, f = info[k]
    if o:
        dyn[kind] += 1; byfn[f] += 1
scale = period / tot / 1e6  # PERIOD is the instructions per run
print(f"samples {tot}, in Map/Set code {sum(dyn.values())}")
print("dynamic, M instructions per run:", ", ".join(f"{k} {v*scale:.0f}" for k, v in sorted(dyn.items())), f"| all {sum(dyn.values())*scale:.0f}")
print("static, instructions:", ", ".join(f"{k} {v}" for k, v in sorted(static.items())))
for f, v in byfn.most_common(8): print(f"  {v*scale:7.1f}M  {f[:100]}")
