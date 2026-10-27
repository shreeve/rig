# census.py BIN OFFS: every conditional jump to an indexPanic block, classified by its compare, weighted by samples.
import re, sys, subprocess, collections
binp, offs = sys.argv[1], sys.argv[2]
syms = {}
for line in subprocess.run(["nm", "-C", "--defined-only", binp], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"([0-9a-f]+) [tTwW] (.*)$", line)
    if m: syms.setdefault(m.group(2), int(m.group(1), 16))
cnt = collections.Counter()
for line in open(offs):
    m = re.match(r"\s*(\d+)\s+(.*)\+0x([0-9a-f]+)\s*$", line)
    if m and m.group(2) in syms: cnt[syms[m.group(2)] + int(m.group(3), 16)] += int(m.group(1))
ins = []
p = subprocess.Popen(["objdump", "-d", "--no-show-raw-insn", binp], stdout=subprocess.PIPE, text=True)
for line in p.stdout:
    m = re.match(r"\s+([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
    if m: ins.append((int(m.group(1), 16), m.group(2), re.sub(r"\s*#.*$", "", m.group(3)).strip()))
idx = {a: k for k, (a, _, _) in enumerate(ins)}
panic = set()
for k, (a, op, args) in enumerate(ins):
    if op.startswith("call") and "<rig.runtime.indexPanic>" in args:
        for back in range(0, 3):
            panic.add(ins[k - back][0])
hot = {}; cls = collections.Counter(); w = collections.Counter(); examples = {}
for k, (a, op, args) in enumerate(ins):
    if not op.startswith("j") or op in ("jmp",): continue
    t = re.match(r"([0-9a-f]+)", args)
    if not t or int(t.group(1), 16) not in panic: continue
    pa, pop, pargs = ins[k - 1]
    if pop.startswith("cmp"):
        src = pargs.split(",")[0]
        kind = "cmp $const" if src.startswith("$") else ("cmp mem" if "(" in pargs else "cmp reg,reg")
    elif pop.startswith("test"): kind = "test (sign)"
    else: kind = "other:" + pop
    # a second test to the same panic within the previous 4 instructions
    dbl = any(ins[k - b][1].startswith("j") and ins[k - b][1] != "jmp" and ins[k - b][2].split()[0] == t.group(1) for b in range(2, 6))
    key = kind + (" [2nd test]" if dbl else "") + " " + op
    cls[key] += 1; w[key] += cnt.get(a, 0) + cnt.get(pa, 0)
    examples.setdefault(key, "%x %s %s; %s %s" % (pa, pop, pargs, op, args))
    hot.setdefault(key, collections.Counter())[a] = cnt.get(a, 0) + cnt.get(pa, 0)
tw = sum(w.values()); allw = sum(cnt.values())
print("sites %d; samples on cmp+jcc %d of %d (%.2f%%)" % (sum(cls.values()), tw, allw, 100.0 * tw / allw))
for key, n in w.most_common(): print("%6d samples %6d sites  %-40s e.g. %s" % (n, cls[key], key, examples[key]))

want = sys.argv[3] if len(sys.argv) > 3 else None
if want:
    for a, n in hot[want].most_common(6):
        k = idx[a]
        print("\n== %d samples at %x" % (n, a))
        for j in range(k - 10, k + 3):
            b, o, g = ins[j]; print("  %s %4s %s %s" % (">>" if b == a else "  ", cnt.get(b, ""), o, g))
