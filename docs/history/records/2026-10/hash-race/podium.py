"""Read a bench/hash/bench-hash report and print, for each sized row,
the fastest table that is not Rig's (FxHash's `rust` left out), over
every row but the `int` ones, the built-in Map's and std.hash's
times, and how Rig's faster one compares. usage: podium.py REPORT"""
import sys
lines=open(sys.argv[1]).read().splitlines()
hdr=lines[0].split()
names=hdr[2:hdr.index('fastest')]
print(f"{'row':22} {'best other':>22} {'Map':>7} {'hash.Map':>9}  verdict (Rig's best vs best other)")
for l in lines[1:]:
    f=l.split()
    if len(f) < 3 or f[0].startswith('int') or f[0] in ('keys', 'first', 'memory:') or f[0].endswith(':'): continue
    try:
        vals={n:float(x) for n,x in zip(names,f[2:2+len(names)]) if x!='-'}
    except ValueError:
        continue
    others={n:v for n,v in vals.items() if n not in('rig-fast','hash-fast','rust')}
    if not others or 'rig-fast' not in vals: continue
    bo=min(others,key=others.get); b=others[bo]
    rigs={n:v for n,v in vals.items() if n in('rig-fast','hash-fast')}
    who_v=min(rigs,key=rigs.get); r=rigs[who_v]
    who='Map' if who_v=='rig-fast' else 'hash.Map'
    ratio=b/r
    v=f"{who} {(ratio-1)*100:.0f}% faster" if ratio>=1 else f"{who} {(1/ratio-1)*100:.0f}% slower ({1/ratio:.1f}x)"
    print(f"{f[0]+' '+f[1]:22} {bo+' '+format(b,'.2f'):>22} {vals['rig-fast']:7.2f} {vals.get('hash-fast',float('nan')):9.2f}  {v}")
