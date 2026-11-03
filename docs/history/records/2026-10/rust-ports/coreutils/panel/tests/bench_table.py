#!/usr/bin/env python3
"""bench_table.py BENCH_PY [RESULTS_JSON]: two Markdown tables, the bench
specs from bench.py and, given a results JSON, every arm's numbers."""
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("bench", sys.argv[1])
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def short(a):
    a = a.replace("|", "\\|").replace("\n", "\\n").replace("\t", "\\t")
    return a if len(a) <= 24 else a[:10] + f"...({len(a)} chars)"


def f(s):
    return f"{s * 1e3:.2f} ms" if s < 1 else f"{s:.3f} s"


print("| # | bench | command | input | env | check | note |")
print("|---|---|---|---|---|---|---|")
for i, x in enumerate(b.B, 1):
    if x.calls:
        cmd = f"{x.util} (per-sample calls)"
    else:
        args = x.args if len(x.args) <= 8 else x.args[:3] + [f"... {len(x.args)} args"]
        cmd = x.util + " " + " ".join(short(a) for a in args)
        if x.reps > 1:
            cmd += f" (x{x.reps})"
    if x.stdin:
        cmd += f" < {{{x.stdin}}}"
    if x.stdout == "null":
        cmd += " > /dev/null"
    inp = ", ".join(f"{k}={v[1]}" for k, v in x.inputs.items())
    env = " ".join(f"{k}={v}" for k, v in x.env.items())
    print(f"| {i} | {x.name.replace('|', '/')} | `{cmd}` | {inp} | {env} | {x.check} | {x.note} |")

if len(sys.argv) > 2:
    data = json.load(open(sys.argv[2]))
    names = list(data["binaries"])
    print()
    hdr = ["bench"] + [f"{n} {k}" for n in names for k in ("min", "median", "RSS")]
    hdr += [f"{n} vs {names[0]}" for n in names[1:]] + ["rounds", "load", "output"]
    print("| " + " | ".join(hdr) + " |")
    print("|" + "---|" * len(hdr))
    for r in data["results"]:
        p = r["per"]
        row = [r["name"].replace("|", "/")]
        for n in names:
            row += [f(p[n]["min_s"]), f(p[n]["median_s"]), f"{p[n]['peak_rss_mb']:.1f} MB"] if n in p else ["absent"] * 3
        for n in names[1:]:
            if n not in p:
                row.append("n/a")
            elif "exit" in r.get("differs", {}).get(n, []):
                row.append("n/a (exit differs)")
            else:
                a, c = p[names[0]]["min_s"], p[n]["min_s"]
                row.append(f"{(a / c - 1) * 100:.0f}% faster" if c < a else f"{(c / a - 1) * 100:.0f}% slower")
        row.append(str(p[names[0]]["rounds"]))
        row.append(f"{r['load']:.1f}")
        row.append("; ".join(f"{n} differs: {', '.join(k)}" for n, k in r.get("differs", {}).items()) or "same")
        print("| " + " | ".join(row) + " |")
