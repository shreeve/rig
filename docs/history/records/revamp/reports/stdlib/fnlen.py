import re,sys
f=sys.argv[1]; names=sys.argv[2:]
lines=open(f).read().split('\n')
starts=[i for i,l in enumerate(lines) if re.match(r'^(    )?(pub )?(inline )?fn \w+',l) or re.match(r'^(    )?const \w+ = (struct|enum|union)',l) or re.match(r'^test ',l)]
for n in names:
    for k,s in enumerate(starts):
        if re.match(r'^(    )?(pub )?(inline )?fn '+n+r'\(',lines[s]):
            e=starts[k+1] if k+1<len(starts) else len(lines)
            # back off doc comments
            while e>s and (lines[e-1].strip().startswith('///') or lines[e-1].strip()==''): e-=1
            print(f"{n}: {s+1}-{e} ({e-s})")
