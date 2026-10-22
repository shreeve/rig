for depth, chain in ((1, 20), (2, 10), (3, 10), (4, 10), (5, 8), (6, 8), (7, 8), (8,8)):
    L = ["struct Tok", "  n: Int", "", "sub main", "  a = Tok(n: 1)", "  b = Tok(n: 2)"]
    for k in range(chain):
        L.append(f"  r{k}: ?Tok = ?a")
    ind = "  "
    for d in range(depth):
        L.append(f"{ind}for _ in 0..2")
        ind += "  "
    for k in range(chain - 1, 0, -1):
        L.append(f"{ind}r{k} = r{k-1}")
    pass
    L.append(f"{ind}r0 = ?b")
    L.append(f"{ind}print(r{chain-1}.n)")
    open(f"perf_chain_{depth}_{chain}.rig", "w").write("\n".join(L) + "\n")
