import re, sys
pat=re.compile(r'(?<![A-Za-z0-9_\)\]])\(([*~])([A-Za-z_][A-Za-z0-9_.]*(?:\[[^()\n]*?\])?)\)([?!])')
tot=0
for p in sys.argv[1:]:
    s=open(p).read()
    n,k=pat.subn(r'\1\2\3',s)
    if k:
        open(p,'w').write(n); print(k,p); tot+=k
print(tot,'total')
