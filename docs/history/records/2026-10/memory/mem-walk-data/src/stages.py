# stages.py: the stage table, Trig (MEMWALK lines, plain/PROJ/err) against tsrs
# (tsrs/PROJ.MODE.memsplit, both modes). MiB = 2^20 B.
import re, sys
M = 1 << 20
def trig(p):
    out = {}
    for l in open(f"plain/{p}/err"):
        if l.startswith("MEMWALK "):
            f = l.split(); d = dict(kv.split("=") for kv in f[2:])
            d = {k: int(v) / M for k, v in d.items()}
            out[f[1]] = d
    return out
def tsrs(p, m):
    out = {}; cur = None
    for l in open(f"tsrs/{p}.{m}.memsplit"):
        if l.startswith("tsrs mem split: "): cur = l.strip()[16:]
        if "split MiB:" in l:
            g = lambda k: float(re.search(k + r" ([\d.]+)", l).group(1))
            out[cur] = dict(arena=g("arena used"), heap=g("heap live"), file=g("file"), total=float(l.split("=")[-1]),
                            other=g("arena unused resident") + g(r"arena other \(regions, untouched used\)") + g("heap retained"))
        if "VmHWM" in l and cur: out.setdefault(cur + "_hwm", float(re.search(r"VmHWM ([\d.]+)", l).group(1)))
    return out
stages = [("after config", "config", None), ("after load (parse + resolve)", "load", "load end"), ("after bind", "bind", "bind end"),
          ("after checker creation", "checkers", "parse end"), ("after check", "check", "check end"), ("exit", "exit", "exit")]
for p in ["empty", "zod3", "ts-pattern"]:
    t = trig(p); s = tsrs(p, "shipped"); g = tsrs(p, "go")
    print(f"\n### {p}\n")
    print("| stage | Trig live (heap + tables) | tsrs shipped live (arena + heap) | tsrs Go live | Trig − Go | Trig anon RSS | tsrs shipped anon | tsrs Go anon | Trig − Go |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for name, tk, sk in stages:
        tl = t[tk]["live"] + t[tk]["tables_res"]; ta = t[tk]["RssAnon"]
        if sk:
            sl = s[sk]["arena"] + s[sk]["heap"]; gl = g[sk]["arena"] + g[sk]["heap"]
            sa = s[sk]["total"] - s[sk]["file"]; ga = g[sk]["total"] - g[sk]["file"]
            print(f"| {name} | {tl:.1f} ({t[tk]['live']:.1f} + {t[tk]['tables_res']:.1f}) | {sl:.1f} ({s[sk]['arena']:.1f} + {s[sk]['heap']:.1f}) | {gl:.1f} ({g[sk]['arena']:.1f} + {g[sk]['heap']:.1f}) | {tl-gl:+.1f} | {ta:.1f} | {sa:.1f} | {ga:.1f} | {ta-ga:+.1f} |")
        else:
            print(f"| {name} | {tl:.1f} | | | | {ta:.1f} | | | |")
    print(f"\nTrig file-backed at check {t['check']['RssFile']:.1f} MiB; Trig VmHWM {t['exit']['VmHWM']:.1f}.")
