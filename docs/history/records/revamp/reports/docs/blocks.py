import re, sys, difflib
def blocks(f):
    out=[]; lines=open(f).read().split('\n'); i=0
    while i < len(lines):
        m = re.match(r'^```rig(.*)$', lines[i])
        if m:
            j=i+1
            while not lines[j].startswith('```'): j+=1
            out.append((i+1, m.group(1).strip(), '\n'.join(lines[i+1:j])))
            i=j
        i+=1
    return out
a=blocks(sys.argv[1]); b=blocks(sys.argv[2])
for (la,ka,ta) in a:
    best=(0,None)
    for (lb,kb,tb) in b:
        r=difflib.SequenceMatcher(None,ta,tb).ratio()
        if r>best[0]: best=(r,lb)
    print(f"{la:5} {ka:12} best={best[0]:.2f} @{best[1]}  {ta.splitlines()[0][:40] if ta else ''}")
