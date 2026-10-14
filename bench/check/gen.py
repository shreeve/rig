"""Generated Rig programs for the check-speed guard (bench/check/guard.py).

Each generator takes a size n and returns {file name: source} for a
module whose entry is `pub sub run()`, growing along one dimension: the
number of functions, statements, fields, variants, methods, or modules.
`program` wraps one in a `main.rig`; `workload` puts every one in one
program.
"""


def funcs(n, p):
    out = [f"fun f{k}(a: Int) -> Int\n  b = a + {k}\n  if b > 3\n    return b * 2\n  b - 1\n" for k in range(n)]
    out.append("pub sub run()\n  print(f0(1))\n")
    return {p + ".rig": "\n".join(out)}


def stmts(n, p):
    s = ["fun big(a: Int) -> Int\n  x0 = a + 1"]
    s += [f"  x{k} = x{k - 1} + {k}" for k in range(1, n)]
    s.append(f"  x{n - 1}\n\npub sub run()\n  print(big(1))\n")
    return {p + ".rig": "\n".join(s)}


def fields(n, p):
    s = ["obj P"] + [f"  f{k}: Int" for k in range(n)]
    args = ", ".join(f"f{k}: {k}" for k in range(n))
    s.append("\nfun total(p: ?P) -> Int\n  t = 0")
    s += [f"  t += p.f{k}" for k in range(n)]
    s.append(f"  t\n\npub sub run()\n  p = P({args})\n  print(total(?p))\n")
    return {p + ".rig": "\n".join(s)}


def variants(n, p):
    s = ["enum E"] + [f"  v{k}" for k in range(n)]
    s.append("\nfun code(e: E) -> Int\n  match e")
    s += [f"    .v{k} => return {k}" for k in range(n)]
    s.append("\npub sub run()\n  print(code(.v0))\n")
    return {p + ".rig": "\n".join(s)}


def methods(n, p):
    s = ["obj O\n  v: Int\n"] + [f"  fun m{k}(?self) -> Int\n    self.v + {k}\n" for k in range(n)]
    s.append("pub sub run()\n  o = O(v: 1)\n  t = 0")
    s += [f"  t += o.m{k}()" for k in range(n)]
    s.append("  print(t)\n")
    return {p + ".rig": "\n".join(s)}


def modules(n, p):
    files = {}
    for m in range(n):
        files[f"{p}_m{m}.rig"] = "\n".join(f"pub fun g{k}(a: Int) -> Int\n  a + {k}\n" for k in range(20))
    s = [f"use {p}_m{m}" for m in range(n)] + ["", "pub sub run()", "  t = 0"]
    s += [f"  t += {p}_m{m}.g1(1)" for m in range(n)]
    s += ["  print(t)", ""]
    files[p + ".rig"] = "\n".join(s)
    return files


def lists(n, p):
    s = ["pub sub run()"]
    s += [f"  l{k}: List[Int] = List()\n  !l{k}.push({k})\n  print(l{k}.len)" for k in range(n)]
    return {p + ".rig": "\n".join(s) + "\n"}


def generics(n, p):
    s = ["obj Box[T]\n  v: T\n\n  fun get(?self) -> ?T\n    ?self.v\n"]
    s += [f"obj T{k}\n  v: Int\n" for k in range(n)]
    s.append("pub sub run()\n  t = 0")
    s += [f"  b{k} = Box[T{k}](v: T{k}(v: {k}))\n  t += b{k}.get().v" for k in range(n)]
    s.append("  print(t)\n")
    return {p + ".rig": "\n".join(s)}


GENERATORS = {f.__name__: f for f in (funcs, stmts, fields, variants, methods, modules, lists, generics)}

# The workload: every generator at a size that makes a program about as
# big, and as slow to check, as Trig's parser and the modules it uses.
WORKLOAD = {"funcs": 4000, "stmts": 4000, "fields": 500, "variants": 500, "methods": 500,
            "modules": 50, "lists": 1000, "generics": 200}


def program(name, n):
    files = GENERATORS[name](n, "w")
    files["main.rig"] = "use w\n\nsub main()\n  w.run()\n"
    return files


def workload():
    files, uses, calls = {}, [], []
    for name, n in WORKLOAD.items():
        p = "w_" + name
        files.update(GENERATORS[name](n, p))
        uses.append(f"use {p}")
        calls.append(f"  {p}.run()")
    files["main.rig"] = "\n".join(uses) + "\n\nsub main()\n" + "\n".join(calls) + "\n"
    return files
