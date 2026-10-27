"""Read a bench/hash/bench-hash report and print, for each sized row,
the fastest table that is not Rig's (FxHash's `rust` left out, as its
stride favours it on the `int` rows), the built-in Map's and std.hash's
times, and how Rig's faster one compares. usage: podium.py REPORT"""
import sys
lines=open(sys.argv[1]).read().splitlines()
hdr=lines[0].split()
names=hdr[2:hdr.index('fastest')]
print(f"{'row':22} {'best other':>22} {'Map':>7} {'hash.Map':>9}  verdict (Rig's best vs best other)")
for l in lines[1:]:
    f=l.split()
    if not f[0].startswith(('int','rnd')) or f[0]=='int': continue
    vals={n:float(x) for n,x in zip(names,f[2:2+len(names)]) if x!='-'}
    others={n:v for n,v in vals.items() if n not in('rig-fast','hash-fast','rust')}
    bo=min(others,key=others.get); b=others[bo]
    r=min(vals['rig-fast'],vals['hash-fast'])
    who='Map' if vals['rig-fast']<=vals['hash-fast'] else 'hash.Map'
    ratio=b/r
    v=f"{who} {(ratio-1)*100:.0f}% faster" if ratio>=1 else f"{who} {(1/ratio-1)*100:.0f}% slower ({1/ratio:.1f}x)"
    print(f"{f[0]+' '+f[1]:22} {bo+' '+format(b,'.2f'):>22} {vals['rig-fast']:7.2f} {vals['hash-fast']:9.2f}  {v}")
