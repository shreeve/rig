#!/usr/bin/env python3
"""viol.py CENSUS_ERR REPLAY_ERR [BIN]: the replay's violations (LRV) by file, kind and the file being checked,
with the file's include reasons and flags; with BIN (an unstripped build), each distinct stack symbolized."""
import collections, subprocess, sys
cen, rep = sys.argv[1], sys.argv[2]
binp = sys.argv[3] if len(sys.argv) > 3 else None
names, reasons, flags = {}, {}, {}
for line in open(cen, errors="replace"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "LRF": names[int(p[1]) + 1] = p[7].split("/corpus/")[-1]
    elif p[0] == "LRI": reasons[int(p[1]) + 1] = p[2]
    elif p[0] == "LRG": flags[int(p[1]) + 1] = p[2:]
vs, base = [], None
for line in open(rep, errors="replace"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "LRV": vs.append(p)
    elif p[0] == "LRMAP": base = int(p[1].split("-")[0], 16)
c = collections.Counter((int(v[2]), int(v[3]), int(v[5])) for v in vs)
for (f, b, cur), n in c.most_common(12):
    print("%3d x %s bits=%d while checking %s | reasons %s flags %s" % (n, names.get(f, f), b, names.get(cur, "-"), reasons.get(f, "")[:120], flags.get(f)))
if binp and base is not None:
    # every recorded violation's stack, symbolized in one addr2line call; each by its reading path
    stacks = [[hex(int(a, 16)) for a in v[6].strip(",").split(",")][:14] if len(v) > 6 and v[6] else [] for v in vs]
    allad = sorted(set(a for st in stacks for a in st))
    sym = {}
    if allad:
        out = subprocess.run(["addr2line", "-a", "-f", "-i", "-C", "-s", "-e", binp] + allad, capture_output=True, text=True).stdout.split("\n")
        cur = None
        for line in out:
            if line.startswith("0x"):
                cur = hex(int(line, 16))
                sym[cur] = []
            elif cur is not None and line and not line[0].isspace() and ":" not in line:
                sym[cur].append(line)
    kinds = collections.Counter()
    example = {}
    for v, st in zip(vs, stacks):
        fns = [f for a in st for f in sym.get(a, [])]
        top = [x for x in fns if not x.startswith(("__lr", "rig.", "math.", "debug.", "ast.", "compiler.Ids", "compiler.Program.binding_at", "__rig_std"))]
        if not fns:
            key = "(no stack)"
        elif any("node_count" in x for x in fns[:8]) and top and "new_synthetic_node" in top[0]:
            key = "synthetic node ids: Ast.node_count (a length only)"
        elif any("build_external_module_container_index" in x for x in top):
            key = "type printing: get_alternative_containing_modules -> build_external_module_container_index (every module's exports)"
        else:
            key = " < ".join(top[:4])
        kinds[key] += 1
        example.setdefault(key, (names.get(int(v[2])), names.get(int(v[5]), "-"), v[3]))
    fl = [l for l in open(rep) if l.startswith("LRFL")]
    print("PATHS: %d recorded of %s violations" % (len(vs), fl[0].split("\t")[4].strip() if fl else "?"))
    for k, n in kinds.most_common(10):
        print("  %3d  %s  [e.g. %s read (bits %s) while checking %s]" % (n, k, example[k][0], example[k][2], example[k][1]))
