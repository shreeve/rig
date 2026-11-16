#!/usr/bin/env python3
"""countsum.py FILE...: per poller, over the last 5 s of a RIG_POLL_COUNT
file: registrations held, share of events, events taken by its own worker,
returns full, looks that found it locked (a second), and the share of all
events each worker took."""
import sys, collections
for path in sys.argv[1:]:
    snaps = collections.OrderedDict()
    for l in open(path):
        f = l.split(); d = dict(zip(f[0::2], f[1::2]))
        snaps.setdefault(int(d["t"]), {})[int(d["w"])] = {k: int(v) for k, v in d.items() if k not in ("t", "w")}
    ts = list(snaps)
    end = ts[-1]
    start = next((t for t in ts if end - t <= 5.2e9), ts[0])
    a, b = snaps[start], snaps[end]
    secs = (end - start) / 1e9
    ev = {w: (b[w]["rd"] + b[w]["wr"]) - (a.get(w, {}).get("rd", 0) + a.get(w, {}).get("wr", 0)) for w in b}
    took = {w: b[w]["took"] - a.get(w, {}).get("took", 0) for w in b}
    tot = sum(ev.values()) or 1
    print("== %s  (%.1f s, %d events/s)" % (path.split("/")[-1], secs, tot / secs))
    print("  w   regs  ev-share  own-share  full/s  miss/s  took-share")
    for w in sorted(b):
        g = lambda k: b[w][k] - a.get(w, {}).get(k, 0)
        own = g("own") / ev[w] if ev[w] else 0
        print("  %d %6d   %5.1f%%    %5.1f%%   %6d  %6d   %5.1f%%" % (w, b[w]["cur"], 100 * ev[w] / tot, 100 * own, g("full") / secs, g("miss") / secs, 100 * took[w] / tot))
