import json, math, statistics as st, sys
V = ["rig-safe","yyjson","simdjson-dom","sonic-rs","simd-json-tape","serde_json","go-v2"]
NAME = {"rig-safe":"std.json","yyjson":"yyjson","simdjson-dom":"simdjson DOM","sonic-rs":"sonic-rs","simd-json-tape":"simd-json (tape)","serde_json":"serde_json","go-v2":"Go json/v2"}
F = ["twitter","twitterescaped","canada","citm_catalog","gsoc-2018","github_events"]
runs = [json.load(open(p)) for p in sys.argv[1:]]
size = runs[0]["size"]; samples = {}
for r in runs:
    for k, v in r["samples"].items(): samples.setdefault(k, []).extend(v)
n = len(samples["twitter|rig-safe"])
def mbs(f, t): return size[f] / t * 1e3
def gm(xs): return math.exp(sum(map(math.log, xs)) / len(xs))
def pct(a, b):  # a against b
    return "%.1f%% faster" % ((a / b - 1) * 100) if a >= b else "%.1f%% slower" % ((1 - a / b) * 100)
for label, agg in (("fastest", min), ("median", st.median)):
    m = {(f, v): mbs(f, agg(samples[f + "|" + v])) for f in F for v in V}
    print("\n### MB/s, %s of %d interleaved rounds\n" % (label, n))
    print("| file | bytes | " + " | ".join(NAME[v] for v in V) + " |")
    print("|---|---:|" + "---:|" * len(V))
    for f in F: print("| %s | %s | %s |" % (f, format(size[f], ","), " | ".join("%.0f" % m[f, v] for v in V)))
    print("| geomean | | " + " | ".join("%.0f" % gm([m[f, v] for f in F]) for v in V) + " |")
    print("\n| file | std.json vs yyjson | best competitor | std.json vs best |")
    print("|---|---|---|---|")
    bests = []
    for f in F:
        b = max(V[1:], key=lambda v: m[f, v]); bests.append(m[f, b])
        print("| %s | %s | %s (%.0f) | %s |" % (f, pct(m[f, "rig-safe"], m[f, "yyjson"]), NAME[b], m[f, b], pct(m[f, "rig-safe"], m[f, b])))
    g = gm([m[f, "rig-safe"] for f in F])
    print("| geomean | %s | per-file best (%.0f) | %s |" % (pct(g, gm([m[f, "yyjson"] for f in F])), gm(bests), pct(g, gm(bests))))
# spread: fastest vs median per row, and per-claim fastest for rig and yyjson
print("\n### Per-claim fastest (MB/s), std.json / yyjson\n")
print("| file | " + " | ".join("claim %d" % (i + 1) for i in range(len(runs))) + " |")
print("|---|" + "---|" * len(runs))
for f in F:
    print("| %s | %s |" % (f, " | ".join("%.0f / %.0f" % (mbs(f, min(r["samples"][f+"|rig-safe"])), mbs(f, min(r["samples"][f+"|yyjson"]))) for r in runs)))
print("\nMedian below fastest, worst row: %.1f%%" % max((st.median(s) / min(s) - 1) * 100 for s in samples.values()))
