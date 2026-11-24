#!/usr/bin/env python3
"""lrana.py ERR [TSV]: the last-read census of one run (the census build's stderr), as a release curve.

Reads the LR* lines lastread-zig's __lr.zig and Program.census_report write:
  LRF index lib dts source nodes imports name   (one per file)
  LRN names_bytes names_count
  LRT t0_ns end_epoch vmhwm_kb
  LRB file+1 kind bytes      kind: 0 tree 1 positions 2 text 3 names 4 binding 5 program binder records 6 owned text
  LRL file+1 bit epoch       bit: 0 tree 1 positions 2 text 3 names 4 binding 5 program binder records
  LRE epoch code a b tid     1 census (load end), 20/21 pool, 30/31 check pass, 10/11 a file's check, 40/41/42/43 a
                             checker's task (start, end, drop start, drop end), 50/51 report
  LRS epoch resident_pages shared_pages
An epoch is 1024 ns since the program started.

Model: each (file, kind) is freed at its last read after the census (event 1), or at event 1 if none; freed memory is
reused perfectly, so RSS falls by the bytes freed. new(t) = RSS(t) - freed(t). Prints the peak today and the peak
with release, when each falls, and splits of what is freed at the peak by kind, category and leaf. TSV: one row per
file with its bytes and last reads (ms since the check pass began).
"""
import bisect
import collections
import sys

PAGE = 4096
EP = 1024 / 1e6  # ms per epoch
KNAME = {0: "tree", 1: "pos", 2: "text", 3: "names", 4: "binding", 5: "progsym", 6: "text"}
BIT_OF = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 2}
KINDS = ["tree", "pos", "text", "names", "binding", "progsym"]
MiB = 1 << 20


def load(path):
    files = {}
    byts = collections.defaultdict(int)
    last = {}
    evs = []
    sms = []
    names = (0, 0)
    t = None
    global lastm
    lastm = collections.defaultdict(list)
    for line in open(path, errors="replace"):
        if not line.startswith("LR"):
            continue
        p = line.rstrip("\n").split("\t")
        tag = p[0]
        if tag == "LRF":
            i = int(p[1])
            files[i] = dict(lib=int(p[2]), dts=int(p[3]), source=int(p[4]), nodes=int(p[5]),
                            imports=[int(x) for x in p[6].split(",") if x], name=p[7])
        elif tag == "LRN":
            names = (int(p[1]), int(p[2]))
        elif tag == "LRT":
            t = (int(p[1]), int(p[2]), int(p[3]))
        elif tag == "LRB":
            byts[(int(p[1]) - 1, int(p[2]))] += int(p[3])
        elif tag == "LRL":
            last[(int(p[1]) - 1, int(p[2]))] = int(p[3])
        elif tag == "LRE":
            evs.append(tuple(int(x) for x in p[1:6]))
        elif tag == "LRS":
            sms.append((int(p[1]), int(p[2]), int(p[3])))
        elif tag == "LRM":
            lastm[(int(p[3]) - 1, int(p[4]))].append((int(p[2]), int(p[5])))
    return files, byts, last, evs, sms, names, t


def category(f):
    if f["lib"]:
        return "lib"
    if f["dts"]:
        return "dts"
    return "src"


SAFE = False


def main():
    global SAFE
    if sys.argv[1] == "--safe":
        SAFE = True
        del sys.argv[1]
    path = sys.argv[1]
    tsv = sys.argv[2] if len(sys.argv) > 2 else None
    files, byts, last, evs, sms, names, t = load(path)
    n = len(files)
    importers = collections.Counter()
    for i, f in files.items():
        for tgt in set(f["imports"]):
            if tgt != i:
                importers[tgt] += 1
    ev = collections.defaultdict(list)
    for e, code, a, b, tid in evs:
        ev[code].append((e, a, b, tid))
    t1 = ev[1][0][0]                       # the census: the load's end
    tc0 = ev[30][0][0] if ev[30] else t1   # the check pass
    tc1 = ev[31][0][0] if ev[31] else t[1]
    tend = t[1]
    # each file's check interval(s), by thread
    checks = collections.defaultdict(list)  # tid -> [(begin, end, file)]
    open_ = {}
    for e, code, a, b, tid in evs:
        if code == 10:
            open_[(tid, a)] = e
        elif code == 11:
            checks[tid].append((open_.pop((tid, a), e), e, a))
    tids = sorted(checks)
    own_end = {}
    for tid in tids:
        for b, e, f in checks[tid]:
            own_end[f] = max(own_end.get(f, 0), e)
    # the safe points: a file's check starting or ending on a checker's thread (events 10, 11), and the pass's end
    bounds = collections.defaultdict(list)
    for e, code, a, b, tid in evs:
        if code in (10, 11):
            bounds[tid].append(e)
    for tid in bounds:
        bounds[tid].sort()

    def safe(r):
        # the first moment past r at which every checker still checking has passed a safe point (each view of a
        # tree that a check held at r is gone); a checker with none left past r holds none
        out = r
        for tid, bs in bounds.items():
            i = bisect.bisect_left(bs, r)
            if i < len(bs):
                out = max(out, bs[i])
        return out

    # releases
    rel = []  # (time, bytes, file, kind)
    for (f, k), nb in byts.items():
        if f not in files or nb <= 0:
            continue
        bit = BIT_OF[k]
        r = max(last.get((f, bit), 0), t1)
        if SAFE and r > t1:
            if lastm:
                # each thread that read it: its next safe point past its own last read (none: it holds no view)
                r = t1
                for tid, e in lastm.get((f, bit), []):
                    if e <= t1:
                        continue
                    bs = bounds.get(tid)
                    q = e
                    if bs:
                        i = bisect.bisect_left(bs, e)
                        if i < len(bs):
                            q = bs[i]
                    r = max(r, q)
            else:
                r = safe(r)
        rel.append((r, nb, f, KNAME[k]))
    rel.sort()
    total = sum(r[1] for r in rel)
    rtimes = [r[0] for r in rel]
    cum = []
    s = 0
    for r in rel:
        s += r[1]
        cum.append(s)

    def freed(tm):
        i = bisect.bisect_right(rtimes, tm)
        return cum[i - 1] if i else 0

    rss = [(e, res * PAGE, sh * PAGE) for e, res, sh in sms]
    peak = max(rss, key=lambda x: x[1])
    newc = [(e, r - (freed(e) if e >= t1 else 0)) for e, r, _ in rss]
    npeak = max(newc, key=lambda x: x[1])
    # the load-end level: RSS just before the census
    pre = [x for x in rss if x[0] <= t1]
    load_peak = max(pre, key=lambda x: x[1]) if pre else (t1, 0, 0)
    chk = [x for x in rss if x[0] > t1]
    check_peak = max(chk, key=lambda x: x[1]) if chk else (t1, 0, 0)

    def when(e):
        if e <= t1:
            return "load (%.0f%% of the load)" % (100.0 * e / max(t1, 1))
        if e <= tc0:
            return "pool made (before the check pass)"
        if e <= tc1:
            return "check, %.0f%% through" % (100.0 * (e - tc0) / max(tc1 - tc0, 1))
        return "after the check pass"

    def ms(e):
        return (e - tc0) * EP

    print("release at: %s" % (("the reader's next safe point (per thread)" if lastm else "the next safe point (every checker past a file boundary)") if SAFE else "the last read"))
    print("run %s: %d files, front-end bytes %.1f MiB, names %.1f MiB (%d), VmHWM %.1f MiB" % (
        path, n, total / MiB, names[0] / MiB, names[1], t[2] / 1024))
    print("clock (ms from the check pass): load end %.0f, check %.0f..%.0f, exit %.0f; checker threads %d" % (
        ms(t1), 0, ms(tc1), ms(tend), len(tids)))
    print("peak today  %.1f MiB at %s (%.0f ms)" % (peak[1] / MiB, when(peak[0]), ms(peak[0])))
    print("load-end peak %.1f MiB at %.0f ms; check peak %.1f MiB at %s" % (load_peak[1] / MiB, ms(load_peak[0]), check_peak[1] / MiB, when(check_peak[0])))
    print("peak w/ release %.1f MiB at %s (%.0f ms): ceiling %.1f MiB (%.1f%% of the peak)" % (
        npeak[1] / MiB, when(npeak[0]), ms(npeak[0]), (peak[1] - npeak[1]) / MiB, 100.0 * (peak[1] - npeak[1]) / peak[1]))
    print("freed by today's peak time %.1f MiB; by the check's end %.1f MiB; at once at the load's end %.1f MiB" % (
        freed(peak[0]) / MiB, freed(tc1) / MiB, freed(t1) / MiB))

    # splits of what is freed at the time of today's peak, and at the new peak
    def split(tm, keyf):
        out = collections.defaultdict(lambda: [0, 0])
        for r, nb, f, k in rel:
            key = keyf(f, k)
            out[key][1] += nb
            if r <= tm:
                out[key][0] += nb
        return out

    for title, keyf in [("kind", lambda f, k: k),
                        ("category", lambda f, k: category(files[f])),
                        ("leaf (imported by no file)", lambda f, k: ("leaf" if importers[f] == 0 else "imported") + "/" + category(files[f]))]:
        for label, tm in [("at today's peak", peak[0]), ("at the new peak", npeak[0]), ("at the check's end", tc1)]:
            sp = split(tm, keyf)
            row = ", ".join("%s %.1f/%.1f" % (key, v[0] / MiB, v[1] / MiB) for key, v in sorted(sp.items(), key=lambda x: -x[1][1]))
            print("  freed/held by %s %s (MiB): %s" % (title, label, row))
    # the ceiling if only part of the records were released
    def ceiling_of(pred):
        sub = sorted((r[0], r[1]) for r in rel if pred(r[2], r[3]))
        ts = [x[0] for x in sub]
        cs = []
        acc = 0
        for x in sub:
            acc += x[1]
            cs.append(acc)

        def fr(tm):
            i = bisect.bisect_right(ts, tm)
            return cs[i - 1] if i else 0
        best = max(r - (fr(e) if e >= t1 else 0) for e, r, _ in rss)
        return (peak[1] - best) / MiB
    subsets = [
        ("all", lambda f, k: True),
        ("tree+pos", lambda f, k: k in ("tree", "pos")),
        ("tree", lambda f, k: k == "tree"),
        ("pos", lambda f, k: k == "pos"),
        ("text", lambda f, k: k == "text"),
        ("binder", lambda f, k: k in ("binding", "progsym")),
        ("names", lambda f, k: k == "names"),
        ("leaf", lambda f, k: importers[f] == 0),
        ("imported", lambda f, k: importers[f] != 0),
        ("lib", lambda f, k: category(files[f]) == "lib"),
        ("dts", lambda f, k: category(files[f]) == "dts"),
        ("src", lambda f, k: category(files[f]) == "src"),
        ("leaf-src", lambda f, k: importers[f] == 0 and category(files[f]) == "src"),
    ]
    print("RELEASED\t%s\t%s\tafter=%.1f" % (path, "\t".join("%d%%=%.1f" % (q * 100, freed(tc0 + q * (tc1 - tc0)) / MiB) for q in (0.0, 0.25, 0.5, 0.75, 1.0)), (total - freed(tc1)) / MiB))
    print("SUBSETS\t%s\t%s" % (path, "\t".join("%s=%.1f" % (nm, ceiling_of(pr)) for nm, pr in subsets)))

    def frac(e):
        if e <= t1:
            return "load"
        if e <= tc0:
            return "pool"
        if e <= tc1:
            return "%.2f" % ((e - tc0) / max(tc1 - tc0, 1))
        return "after"
    kinds_new = split(npeak[0], lambda f, k: k)
    cats_new = split(npeak[0], lambda f, k: category(files[f]))
    leaf_new = split(npeak[0], lambda f, k: "leaf" if importers[f] == 0 else "imported")
    print("SUMMARY\t%s\t%.1f\t%s\t%.1f\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s\t%s" % (
        path, peak[1] / MiB, frac(peak[0]), npeak[1] / MiB, frac(npeak[0]), (peak[1] - npeak[1]) / MiB,
        load_peak[1] / MiB, total / MiB, freed(npeak[0]) / MiB,
        ",".join("%s=%.1f" % (k, kinds_new[k][0] / MiB) for k in ["tree", "pos", "text", "names", "binding", "progsym"] if k in kinds_new),
        ",".join("%s=%.1f/%.1f" % (k, v[0] / MiB, v[1] / MiB) for k, v in sorted(cats_new.items())),
        ",".join("%s=%.1f/%.1f" % (k, v[0] / MiB, v[1] / MiB) for k, v in sorted(leaf_new.items())),
        "%.1f" % (freed(peak[0]) / MiB)))
    if tsv:
        # which file each checker was checking at a time
        def checking(tm):
            out = []
            for tid in tids:
                cs = checks[tid]
                lo = 0
                for b, e, f in cs:
                    if b <= tm <= e:
                        out.append(str(f))
                        break
                else:
                    out.append("-")
            return ",".join(out)
        with open(tsv, "w") as o:
            o.write("file\tcategory\timporters\town_check_end_ms\t" + "\t".join("%s_B" % k for k in KINDS) + "\t" + "\t".join("%s_last_ms" % k for k in KINDS) + "\tchecking_at_last_tree\tname\n")
            for i in sorted(files):
                f = files[i]
                b = [byts.get((i, 0), 0), byts.get((i, 1), 0), byts.get((i, 2), 0) + byts.get((i, 6), 0), byts.get((i, 3), 0), byts.get((i, 4), 0), byts.get((i, 5), 0)]
                ls = []
                for bit in range(6):
                    e = last.get((i, bit))
                    ls.append("%.1f" % ms(max(e, t1)) if e is not None else "load")
                lt = last.get((i, 0))
                o.write("%d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n" % (i, category(f), importers[i], "%.1f" % ms(own_end[i]) if i in own_end else "-",
                                                         "\t".join(map(str, b)), "\t".join(ls), checking(lt) if lt else "-", f["name"]))
    # the curve, for plots: every 50th sample
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as o:
            o.write("ms\trss_MiB\tnew_MiB\tfreed_MiB\n")
            for (e, r, _), (_, nw) in list(zip(rss, newc))[::10]:
                o.write("%.1f\t%.2f\t%.2f\t%.2f\n" % (ms(e), r / MiB, nw / MiB, (freed(e) if e >= t1 else 0) / MiB))


main()
