import sys
SIZES = {"U8":1,"I8":1,"U16":2,"I16":2,"U32":4,"I32":4,"U64":8,"I64":8}
combos = []
for t in ["U8","I8","U16","I16","U32","I32","U64","I64"]:
    for n in [2,4,8,16,32,64]:
        ends = [None] if SIZES[t]==1 else [".little",".big"]
        for e in ends:
            combos.append((t,n,e))
out = []
def ty(t,n,e):
    return f"Simd[{t}, {n}]" + (f", {e}" if e else "")
def scal(t,e,src,at):
    if SIZES[t]==1:
        return f"{t}({src}[{at}])" if t=="U8" else None
    return f"{src}.read[{t}, {e}]({at})"
fn = []
for (t,n,e) in combos:
    b = SIZES[t]*n
    nm = f"{t}_{n}_{(e or '.x')[1:]}"
    T = ty(t,n,e)
    sc = scal(t,e,"r","off + j * %d" % SIZES[t])
    # List: read + write; String: read
    for kind in ["l","s"]:
        par = "xs: !List[U8]" if kind=="l" else "t: ?String"
        src = "xs" if kind=="l" else "t"
        out.append(f"sub {kind}_{nm}({par})")
        out.append(f"  off = {src}.len - {b} - 17")
        out.append(f"  if off < 0")
        out.append(f"    off = 0")
        out.append(f"  while off <= {src}.len - {b}")
        out.append(f"    v = {src}.read[{T}](off)")
        out.append(f"    a = v.array()")
        out.append(f"    for j in 0..{n}")
        if t=="U8":
            out.append(f"      if a[j] != {src}[off + j]")
        elif t=="I8":
            out.append(f"      u = {src}[off + j]")
            out.append(f"      if (a[j] < 0) != (u >= 128) or U8(a[j] & 127) != (u & 127)")
        else:
            out.append(f"      if a[j] != {src}.read[{t}, {e}](off + j * {SIZES[t]})")
        out.append(f"        print(\"bad read {kind} {nm}\", {src}.len, off, j)")
        if kind=="l":
            out.append(f"    !xs.write[{T}](off, v +% 1)")
            out.append(f"    w = xs.read[{T}](off)")
            out.append(f"    if not (w == v +% 1).all()")
            out.append(f"      print(\"bad write {nm}\", xs.len, off)")
            out.append(f"    !xs.write[{T}](off, v)")
        out.append(f"    off += 1")
        out.append("")
        fn.append((kind,nm,b))
out.append("sub main()")
out.append("  count = 0")
# List lengths: powers of two, exact capacity
for L in [4,8,16,32,64,128,256,512,1024]:
    out.append(f"  xs{L}: List[U8] = List()")
    out.append(f"  for i in 0..{L}")
    out.append(f"    !xs{L}.push(U8((i * 37 + 11) % 256))")
# Strings: from empty, pushes give capacity 129, then 323, then 323+161+128=614
for L in [129, 323, 614]:
    out.append(f"  t{L} = String()")
    out.append(f"  for i in 0..{L}")
    out.append(f"    !t{L}.push(U8((i * 53 + 7) % 256))")
for (kind,nm,b) in fn:
    if kind=="l":
        for L in [4,8,16,32,64,128,256,512,1024]:
            if L >= b and L <= 4*b + 64:
                out.append(f"  l_{nm}(!xs{L})")
                out.append(f"  count += 1")
    else:
        for L in [129,323,614]:
            if L >= b:
                out.append(f"  s_{nm}(?t{L})")
                out.append(f"  count += 1")
out.append("  print(\"done\", count)")
print("\n".join(out))
