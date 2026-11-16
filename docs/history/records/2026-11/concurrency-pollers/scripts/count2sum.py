#!/usr/bin/env python3
"""count2sum.py FILE...: rates a second, summed over the workers, over the
last 5 s of each RIG_POLL_COUNT file (count2.patch): registration events,
kqueue waits, looks at a worker's own poller and at others', looks that
found a poller locked, sleeps, fibers run, steals, monitor signals and
preemption stops, and worker 0's poller's share of the events."""
import sys, collections
K = ["rd", "wr", "waits", "lkown", "lkother", "miss", "slept", "ran", "stole", "sig", "pre", "full"]
print("| run | events | waits | own looks | other looks | locked | sleeps | fibers run | steals | signals | stops | full | w0 share |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for path in sys.argv[1:]:
    snaps = collections.OrderedDict()
    for l in open(path):
        f = l.split(); d = dict(zip(f[0::2], f[1::2]))
        snaps.setdefault(int(d["t"]), {})[int(d["w"])] = {k: int(v) for k, v in d.items() if k not in ("t", "w")}
    ts = list(snaps); end = ts[-1]
    start = next((t for t in ts if end - t <= 5.2e9), ts[0])
    a, b = snaps[start], snaps[end]; secs = (end - start) / 1e9
    tot = {k: sum(b[w][k] - a.get(w, {}).get(k, 0) for w in b) / secs for k in K}
    ev = tot["rd"] + tot["wr"]
    w0 = ((b[0]["rd"] + b[0]["wr"]) - (a[0]["rd"] + a[0]["wr"])) / secs / ev if ev else 0
    name = path.split("/")[-1][:-4]
    print("| %s | %dk | %dk | %dk | %dk | %dk | %dk | %dk | %dk | %dk | %dk | %d | %.0f%% |" % (name, ev / 1e3, tot["waits"] / 1e3, tot["lkown"] / 1e3, tot["lkother"] / 1e3, tot["miss"] / 1e3, tot["slept"] / 1e3, tot["ran"] / 1e3, tot["stole"] / 1e3, tot["sig"] / 1e3, tot["pre"] / 1e3, tot["full"], 100 * w0))
