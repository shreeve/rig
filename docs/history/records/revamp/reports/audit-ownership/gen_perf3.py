for depth in (8, 10, 12, 14):
    L = ["struct Tok", "  n: Int", "", "sub main", "  t = *Tok(n: 0)", "  s = 0"]
    ind = "  "
    for d in range(depth):
        L.append(f"{ind}for _ in 0..2")
        ind += "  "
    L.append(f"{ind}u = +t")
    L.append(f"{ind}s += u.n")
    L.append("  print(s)")
    open(f"perf_n{depth}.rig", "w").write("\n".join(L) + "\n")
