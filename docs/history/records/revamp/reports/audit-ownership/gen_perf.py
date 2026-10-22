import sys
for depth in (6, 8, 10, 12):
    lines = ["struct Tok", "  n: Int", "", "sub main", "  t = *Tok(n: 0)", "  s = 0"]
    ind = "  "
    for d in range(depth):
        lines.append(f"{ind}for i{d} in 0..2")
        ind += "  "
    lines.append(f"{ind}u = +t")
    lines.append(f"{ind}s += u.n + i{depth-1}")
    lines.append("  print(s)")
    open(f"perf_nest{depth}.rig", "w").write("\n".join(lines) + "\n")

# many views chained: v0 = ?x, v1 = View(b: ?...)...
for n in (50, 200, 800):
    lines = ["struct Tok", "  n: Int", "", "struct V", "  b: ?Tok", "", "sub main", "  x = Tok(n: 1)"]
    for i in range(n):
        lines.append(f"  v{i} = V(b: ?x)")
    for i in range(n):
        lines.append(f"  print(v{i}.b.n)")
    open(f"perf_views{n}.rig", "w").write("\n".join(lines) + "\n")
