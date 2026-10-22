import os, sys
S = os.path.dirname(os.path.abspath(__file__))
NF = int(sys.argv[1]); NM = int(sys.argv[2]); CALLS = int(sys.argv[3]); name = sys.argv[4]
d = os.path.join(S, name); os.makedirs(d, exist_ok=True)
lib = ["pub struct Wrap[T]\n  v: T\n\n  fun get(?self) -> T\n    self.v\n"]
for i in range(NF):
    # each generic calls the previous one: chain of generic uses
    body = f"  f{i-1}(a, b) + 1\n" if i > 0 else "  if a > b\n    1\n  else\n    0\n"
    lib.append(f"pub fun f{i}[T](a: T, b: T) -> Int\n{body}")
    lib.append(f"pub fun g{i}[T](x: T) -> Wrap[T]\n  Wrap(v: x)\n")
open(os.path.join(d, "lib.rig"), "w").write("\n".join(lib))
mains = ["use lib"]
for m in range(NM):
    lines = ["use lib", "", f"pub fun m{m}() -> Int", "  t = 0"]
    tys = ["Int", "Float", "U8", "I32", "U16", "I64", "U32", "F32"]
    for c in range(CALLS):
        i = (c * 7 + m) % NF
        ty = tys[(c + m) % len(tys)]
        lines.append(f"  t += lib.f{i}[{ty}](1, 2)")
        lines.append(f"  w{c}: lib.Wrap[{ty}] = lib.g{i}[{ty}](1)")
        lines.append(f"  t += 0 if w{c}.get() > 0 else 1")
    lines.append("  t")
    open(os.path.join(d, f"u{m}.rig"), "w").write("\n".join(lines) + "\n")
    mains.append(f"use u{m}")
mains += ["", "sub main()", "  t = 0"] + [f"  t += u{m}.m{m}()" for m in range(NM)] + ["  print(t)"]
open(os.path.join(d, "main.rig"), "w").write("\n".join(mains) + "\n")
