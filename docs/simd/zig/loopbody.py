#!/usr/bin/env python3
"""loopbody.py: instructions in the innermost-first loop of each mask_* kernel (per 64-byte block)."""
import sys, re, importlib.util, os
spec = importlib.util.spec_from_file_location("asm", os.path.join(os.path.dirname(__file__), "asm.py"))
src = open(os.path.join(os.path.dirname(__file__), "asm.py")).read().split("if sys.argv[1] == '--counts'")[0]
ns = {}; exec(src, ns)
tg = ["a64","x64v1","x64v2","x64v3","wasm","wasmsimd"]
names = ["mask_simd16","mask_simd32","mask_simd64","mask_neon_addp","mask_portable_addp","mask_nibble","mask_swar64","mask_swar128","mask_scalar"]
data = {t: ns["funcs"](f"out/kern/{t}/kernels.s") for t in tg}
def body(lines, wasm):
    if wasm:
        # instructions between the first 'loop' and its matching 'end_loop'
        try: i = next(k for k,l in enumerate(lines) if l.startswith('loop'))
        except StopIteration: return None
        depth=0; n=0
        for l in lines[i:]:
            if l.startswith(('loop','block')): depth+=1
            elif l.startswith(('end_loop','end_block')):
                depth-=1
                if depth==0: break
            else: n+=1
        return n
    labels = {l[:-1]: k for k,l in enumerate(lines) if l.endswith(':')}
    best=None
    for k,l in enumerate(lines):
        m = re.search(r'\b(b\.\w+|b|cbnz|cbz|tbnz|tbz|j\w+)\s+(?:\w+,\s*)*([.\w]+)$', l.replace('\t',' '))
        if m and m.group(2) in labels and labels[m.group(2)] < k:
            seg = [x for x in lines[labels[m.group(2)]:k+1] if not x.endswith(':')]
            n = len(seg)
            # blocks per iteration = 64-bit mask stores (nibble kernel stores 4 per block)
            st = sum(1 for x in seg if re.match(r'(mov\s+qword ptr \[rdx|st1\.d|str\s+x\d+, \[x2|stp\s+x\d+, x\d+, \[x2|str\s+d\d+, \[x2|stp\s+d|movq\s+qword ptr \[rdx|vmovq\s+qword ptr \[rdx|movlps|vmovlps|movhps|vmovhps|vmovups\s+[xy]mmword ptr \[rdx|movups\s+xmmword ptr \[rdx|vmovdqu\s+[xy]mmword ptr \[rdx|movdqu\s+xmmword ptr \[rdx|st1\.2d|str\s+q\d+, \[x2)', x.replace('\t',' ')))
            if best is None or n > best[0]: best = (n, st)
    return f"{best[0]}/{best[1]}st" if best else None
print(f"{'kernel (per 64B)':22}" + "".join(f"{t:>9}" for t in tg))
for n in names:
    print(f"{n:22}" + "".join(f"{str(body(data[t][n], t.startswith('wasm')) if n in data[t] else '-'):>9}" for t in tg))
