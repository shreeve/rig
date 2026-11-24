#!/usr/bin/env python3
"""floors.py: the two sound floors of the release question, from a census run (the cen4 build's stderr).

  floors.py table ERR MAINOUT FLOOR OUT      the replay's table (LR_FLOOR) for floor 1 or 2
  floors.py model ERR MAINOUT [ERR...]       the floors' ceilings for each run (and the oracle's, lrana's model)

Floor 1 (leaf): a checked module file no file includes (import, reference, type or lib directive), not pinned, is
released when its own check ends. Floor 2 (importers done): a file is released once every checked file that can
reach it (transitively over the include graph: imports, references, type and lib directives, its own strongly
connected component included) has finished its check; a file reachable from a pinned file is never released.
Pinned (never released, both floors): bundled libs, global scripts (neither ES nor CommonJS module), files with a
module augmentation, `declare global`, an ambient module declaration or `export as namespace`, and files included
by a `/// <reference path>`, a type reference directive or the automatic type directives (tsconfig `types`, @types).
The text of a file with a diagnostic in main's output is kept to the end (the report); bind diagnostics are never
released. Releases happen at file-check ends (a group's last checked file) or when the check pass starts.
Released kinds: tree 1, positions 2, text 4, names 8, binding 16, program binder records 32.
"""
import bisect
import collections
import os
import re
import sys

sys.setrecursionlimit(100000)
MiB = 1 << 20
PAGE = 4096


def load(path):
    st = dict(files={}, flags={}, reasons={}, byts=collections.defaultdict(int), evs=[], sms=[], last={})
    for line in open(path, errors="replace"):
        if not line.startswith("LR"):
            continue
        p = line.rstrip("\n").split("\t")
        t = p[0]
        if t == "LRF":
            st["files"][int(p[1])] = dict(lib=int(p[2]), dts=int(p[3]), imports=[int(x) for x in p[6].split(",") if x], name=p[7])
        elif t == "LRG":
            st["flags"][int(p[1])] = dict(module=int(p[2]), aug=int(p[3]), ambient=int(p[4]), glob=int(p[5]), umd=int(p[6]))
        elif t == "LRI":
            rs = []
            for x in p[2].split(","):
                if x:
                    k, f = x.split(":")
                    rs.append((k, int(f)))
            st["reasons"][int(p[1])] = rs
        elif t == "LRB":
            st["byts"][(int(p[1]) - 1, int(p[2]))] += int(p[3])
        elif t == "LRE":
            st["evs"].append(tuple(int(x) for x in p[1:6]))
        elif t == "LRS":
            st["sms"].append((int(p[1]), int(p[2]) * PAGE))
        elif t == "LRL":
            st["last"][(int(p[1]) - 1, int(p[2]))] = int(p[3])
    return st


def diag_files(st, mainout):
    """Files with a diagnostic in main's stdout, by index."""
    rels = set()
    for line in open(mainout, errors="replace"):
        m = re.match(r"^(.+?)\((\d+),(\d+)\): ", line)
        if m:
            rels.add(m.group(1))
    out = set()
    if not rels:
        return out
    for i, f in st["files"].items():
        for r in rels:
            if f["name"].endswith("/" + r) or f["name"] == r:
                out.add(i)
    return out


def report_text_files(st):
    """Files whose text the census saw read after every file's check had ended (at c1): the program's pass over the
    diagnostics (comment directives such as @ts-expect-error, suppressed diagnostics included) and the report (files
    with a diagnostic, and the files its related information points into)."""
    # after the last file's check: the program's own pass over the diagnostics (comment directives such as
    # @ts-expect-error read the file's text) and the report
    ends = [e for e, code, a, b, tid in st["evs"] if code == 11]
    if not ends:
        return set()
    return set(f for (f, bit), e in st["last"].items() if bit == 2 and e >= max(ends))  # the clock ticks in ~70 us steps


def graph(st):
    n = len(st["files"])
    edges = collections.defaultdict(set)  # from -> to
    for i, f in st["files"].items():
        for t in f["imports"]:
            if t >= 0 and t != i:
                edges[i].add(t)
    for i, rs in st["reasons"].items():
        for k, frm in rs:
            if k in "IRTL" and frm >= 0 and frm != i:
                edges[frm].add(i)
    return n, edges


def pinned(st):
    out = set()
    for i, f in st["files"].items():
        fl = st["flags"].get(i, {})
        rs = st["reasons"].get(i, [])
        if f["lib"] or not fl.get("module", 0) or fl.get("aug", 0) or fl.get("ambient", 0) or fl.get("glob", 0) or fl.get("umd", 0):
            out.add(i)
        elif any(k in "RTALB" for k, _ in rs):
            out.add(i)
    return out


def checked_files(st):
    return set(a for e, code, a, b, tid in st["evs"] if code == 11)


def sccs(n, edges):
    index = [-1] * n
    low = [0] * n
    on = [False] * n
    comp = [-1] * n
    stack = []
    ncomp = 0
    counter = 0
    for root in range(n):
        if index[root] >= 0:
            continue
        # iterative Tarjan
        work = [(root, iter(sorted(edges.get(root, ()))))]
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on[root] = True
        while work:
            v, it = work[-1]
            advanced = False
            for w in it:
                if index[w] < 0:
                    index[w] = low[w] = counter
                    counter += 1
                    stack.append(w)
                    on[w] = True
                    work.append((w, iter(sorted(edges.get(w, ())))))
                    advanced = True
                    break
                elif on[w]:
                    low[v] = min(low[v], index[w])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[v])
            if low[v] == index[v]:
                while True:
                    w = stack.pop()
                    on[w] = False
                    comp[w] = ncomp
                    if w == v:
                        break
                ncomp += 1
    return comp, ncomp


def plan(st, mainout, floor, checked=None):
    """(group of each file or -1, pending of each group, edges of each group, bits of each file, checked set, keep)."""
    n, edges = graph(st)
    pin = pinned(st)
    keep = diag_files(st, mainout) | report_text_files(st)
    if checked is None:
        checked = checked_files(st)
    bits = {}
    for i in range(n):
        b = 1 | 2 | 8 | 16 | 32 | (0 if i in keep else 4)
        bits[i] = 0 if i in pin else b
    if floor == 1:
        incoming = collections.Counter()
        for frm, tos in edges.items():
            for t in tos:
                incoming[t] += 1
        group, pending, gedges = {}, [], []
        for i in range(n):
            if bits[i] and incoming[i] == 0 and i in checked:
                group[i] = len(pending)
                pending.append(1)
                gedges.append([])
            else:
                group[i] = -1
                bits[i] = 0
        return group, pending, gedges, bits, checked, keep
    comp, nc = sccs(n, edges)
    pending = [0] * nc
    gedges = [set() for _ in range(nc)]
    importers = [set() for _ in range(nc)]
    for i in range(n):
        if i in checked:
            pending[comp[i]] += 1
        if i in pin:
            pending[comp[i]] += 1 << 30   # never done: what a pinned file reaches stays
    for frm, tos in edges.items():
        for t in tos:
            a, b = comp[frm], comp[t]
            if a != b:
                gedges[a].add(b)
                importers[b].add(a)
    for c in range(nc):
        pending[c] += len(importers[c])
    group = {i: comp[i] for i in range(n)}
    return group, pending, [sorted(x) for x in gedges], bits, checked, keep


def write_table(st, mainout, floor, out):
    group, pending, gedges, bits, checked, keep = plan(st, mainout, floor)
    ng = len(pending)
    ne = sum(len(x) for x in gedges)
    members = sorted((g, i) for i, g in group.items() if g >= 0)
    with open(out, "w") as o:
        o.write("G %d %d %d\n" % (ng, ne, len(members)))
        for g in range(ng):
            o.write("P %d %d\n" % (g, pending[g]))
        for g in range(ng):
            for h in gedges[g]:
                o.write("E %d %d\n" % (g, h))
        for g, i in members:
            o.write("F %d %d %d %d\n" % (i + 1, g, bits[i], 1 if i in checked else 0))
        for i, g in group.items():
            if g < 0:
                o.write("F %d -1 0 %d\n" % (i + 1, 1 if i in checked else 0))
    released = sum(1 for i in group if bits[i])
    print("floor %d: %d groups, %d edges, %d files of %d releasable, %d kept-text files, %d checked" % (
        floor, ng, ne, released, len(group), len(keep), len(checked)))


KBIT = {0: 1, 1: 2, 2: 4, 3: 8, 4: 16, 5: 32, 6: 4}


def simulate(st, group, pending, gedges, bits, checked):
    """Release time of each file under a plan, by the run's events (30: groups at 0; 11: a file's check ends)."""
    pending = list(pending)
    done = [False] * len(pending)
    rel = {}
    seen = set()

    def release(g0, e):
        stack = [g0]
        done[g0] = True
        while stack:
            g = stack.pop()
            for i in members[g]:
                rel[i] = e
            for h in gedges[g]:
                pending[h] -= 1
                if pending[h] == 0 and not done[h]:
                    done[h] = True
                    stack.append(h)
    members = collections.defaultdict(list)
    for i, g in group.items():
        if g >= 0:
            members[g].append(i)
    prev = {}

    def finish(a, e):
        if a in seen:
            return
        seen.add(a)
        g = group.get(a, -1)
        if g >= 0 and a in checked:
            pending[g] -= 1
            if pending[g] == 0 and not done[g]:
                release(g, e)
    # a file is done once its diagnostics are taken: its thread's next check, its checker's end, or the pass's end
    for e, code, a, b, tid in sorted(st["evs"], key=lambda x: x[0]):
        if code == 30:
            for g in range(len(pending)):
                if pending[g] == 0 and not done[g]:
                    release(g, e)
        elif code == 10:
            if prev.get(tid) is not None:
                finish(prev.pop(tid), e)
        elif code == 11:
            prev[tid] = a
        elif code in (41, 31):
            if prev.get(tid) is not None:
                finish(prev.pop(tid), e)
    return rel


def ceiling(st, rel_items):
    """rel_items: (time, bytes). The peak today, the peak with release, the ceiling, in MiB."""
    rel_items = sorted(rel_items)
    ts = [x[0] for x in rel_items]
    cs = []
    acc = 0
    for x in rel_items:
        acc += x[1]
        cs.append(acc)

    def fr(t):
        i = bisect.bisect_right(ts, t)
        return cs[i - 1] if i else 0
    t1 = [e for e, code, a, b, tid in st["evs"] if code == 1][0]
    peak = max(r for e, r in st["sms"])
    new = max(r - (fr(e) if e >= t1 else 0) for e, r in st["sms"])
    return peak / MiB, new / MiB, (peak - new) / MiB


def floor_model(st, mainout, floor, checked):
    group, pending, gedges, bits, checked, keep = plan(st, mainout, floor, checked)
    rel = simulate(st, group, pending, gedges, bits, checked)
    items = []
    by = collections.Counter()
    for (f, k), nb in st["byts"].items():
        if f in rel and bits.get(f, 0) & KBIT[k]:
            items.append((rel[f], nb))
            by[k] += nb
    return ceiling(st, items), sum(by.values()) / MiB, len(set(rel) & set(i for i in bits if bits[i]))


def main():
    cmd = sys.argv[1]
    if cmd == "table":
        st = load(sys.argv[2])
        write_table(st, sys.argv[3], int(sys.argv[5 - 1]), sys.argv[5])
        return
    if cmd == "model":
        mainout = sys.argv[2]
        c1 = None
        for path in sys.argv[3:]:
            st = load(path)
            if c1 is None:
                c1 = checked_files(st)
            out = [os.path.basename(path)]
            n, edges = graph(st)
            out.append("files=%d pinned=%d keep=%d" % (n, len(pinned(st)), len(diag_files(st, mainout))))
            for fl in (1, 2):
                (peak, new, ceil), relb, nrel = floor_model(st, mainout, fl, c1)
                out.append("floor%d=%.1f (peak %.1f new %.1f; %d files, %.1f MiB released by the end)" % (fl, ceil, peak, new, nrel, relb))
            print("\t".join(out))


main()
