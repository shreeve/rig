#!/usr/bin/env python3
"""asm.py FILE.s [func...]  -- print per-function instructions (directives stripped)
   asm.py --counts BASE [mode]  -- instruction-count table for out/*/MODE/BASE.s"""
import sys, re, os, glob
TGTS = ["a64","a64lin","x64v1","x64v2","x64v3","wasm","wasmsimd"]
def funcs(path):
    out = {}; cur = None
    for line in open(path):
        s = line.rstrip()
        if not s: continue
        base = os.path.basename(path)[:-2]
        m = re.match(r'^(?:_|l_|\.L|L)?' + re.escape(base) + r'\.(\w+):', s)
        if m:
            cur = m.group(1); out.setdefault(cur, []); continue
        if re.match(r'^[^\s].*:', s) and not re.match(r'^(\.?LBB|Lloh|Ltmp|\.Ltmp)', s):
            cur = None; continue
        if cur is None: continue
        t = s.strip()
        if re.match(r'^\.?LBB\w*:$', t):
            out[cur].append(t); continue
        if t.startswith(('.', '#', '//', ';')) or t.startswith('end_function'):
            if t.startswith('end_function'): cur = None
            continue
        if re.match(r'^[.\w$]+:$', t):
            if not t.startswith(('Lloh','Ltmp','.Ltmp')): out[cur].append(t)
            continue  # keep branch labels only
        if t.startswith(('.functype','.local')): continue
        out[cur].append(t)
    return out
def ninstr(lines): return sum(1 for l in lines if not l.endswith(':'))
if sys.argv[1] == '--counts':
    base = sys.argv[2]; mode = sys.argv[3] if len(sys.argv)>3 else 'ReleaseFast'
    data = {t: funcs(f"out/{t}/{mode}/{base}.s") for t in TGTS if os.path.exists(f"out/{t}/{mode}/{base}.s")}
    names = sorted({n for d in data.values() for n in d}, key=lambda n: min((list(d).index(n) if n in d else 999) for d in data.values()))
    print(f"{'fn':24}" + "".join(f"{t:>9}" for t in data))
    for n in names:
        print(f"{n:24}" + "".join(f"{(ninstr(data[t][n]) if n in data[t] else '-'):>9}" for t in data))
else:
    fs = funcs(sys.argv[1])
    for n, lines in fs.items():
        if len(sys.argv) > 2 and n not in sys.argv[2:]: continue
        print(f"--- {n} ({ninstr(lines)} instr)")
        for l in lines: print("   ", l)
