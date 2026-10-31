#!/usr/bin/env python3
"""hdr.py BIN IPS: samples on loads of a container header (a Table base,
a List pointer or length) from a field of a lent object: an instruction
`mov OFF(%reg),%reg` or `cmp OFF(%reg),...` whose innermost inline frame is
Table.constSlot/slot/items or ListOf mem/memConst/len/indexOf/push."""
import sys, subprocess, collections, re
bin_, ips = sys.argv[1], sys.argv[2]
cnt = collections.Counter(int(l, 16) for l in open(ips) if l.strip())
tot = sum(cnt.values())
d = subprocess.run(["objdump", "-d", "--no-show-raw-insn", bin_], capture_output=True, text=True).stdout
ins = {}
for l in d.splitlines():
    m = re.match(r"\s*([0-9a-f]+):\s+(.*)", l)
    if m: ins[int(m.group(1), 16)] = m.group(2)
cand = [a for a, t in ins.items() if re.match(r"(mov|cmp)\s+0x[0-9a-f]+\(%r[a-z0-9]+\),", t)]
p = subprocess.run(["/usr/lib/llvm-22/bin/llvm-symbolizer", f"--obj={bin_}", "--functions=linkage", "--demangle"],
                   input="\n".join(hex(a) for a in cand) + "\n", capture_output=True, text=True)
blocks = p.stdout.strip("\n").split("\n\n")
hit = collections.Counter(); static = collections.Counter()
for a, b in zip(cand, blocks):
    fn = b.split("\n")[0]
    k = None
    if re.search(r"table\.Table\(.*\)\.(constSlot|slot|items)", fn): k = "Table base"
    elif re.search(r"ListOf\(.*\)\.(mem|memConst|indexOf|push|len|at|slot|constSlot)", fn) or re.search(r"runtime\.(lenOf|heldLen)", fn): k = "List header"
    if k:
        static[k] += 1
        # the sample on a load lands on it or the next instruction (skid)
        hit[k] += cnt.get(a, 0)
for k in static: print(f"{k}: {static[k]} load sites, {100*hit[k]/tot:.2f}% of samples on them")
