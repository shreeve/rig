import sys,statistics as st,collections as C
runs=C.defaultdict(list)
for l in open(sys.argv[1]):
    if l.startswith('#'): continue
    f=l.split(); kv=dict(x.split('=',1) for x in f[1:] if '=' in x)
    runs[(f[0],kv['arm'])].append((float(kv['wall_ms']),int(kv['rss_kb'])))
projs=sorted({p for p,a in runs})
med=lambda p,a,i: st.median(r[i] for r in runs[(p,a)])
S=lambda xs: ' | '.join(xs)
print('Medians of 10 rounds. M = main b1r (Rig 383a1b2b5); B = knob unset (N=2); X = N=8; Y = N=32. Wall in ms, peak RSS in MiB; the % columns are against M at the same count.\n')
for c in '1248':
    print('### c%s\n'%c)
    print('| project | M wall | B | X | Y | M RSS | B | X | Y |'); print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    tot=[0]*8
    for p in projs:
        mw,mr=med(p,'M'+c,0),med(p,'M'+c,1)
        row=['%.0f'%mw]+['%+.1f%%'%(100*(med(p,x+c,0)/mw-1)) for x in 'BXY']+['%.0f'%(mr/1024)]+['%+.1f%%'%(100*(med(p,x+c,1)/mr-1)) for x in 'BXY']
        print('| %s%s | %s |'%(p,' (not summed)' if p=='mui-docs' else '',S(row)))
        if p!='mui-docs':
            for i,a in enumerate('MBXY'): tot[i]+=med(p,a+c,0); tot[4+i]+=med(p,a+c,1)
    print('| **16 summed** | %.0f | %s | %.0f | %s |\n'%(tot[0],S('%+.1f%%'%(100*(tot[i]/tot[0]-1)) for i in (1,2,3)),tot[4]/1024,S('%+.1f%%'%(100*(tot[4+i]/tot[4]-1)) for i in (1,2,3))))
