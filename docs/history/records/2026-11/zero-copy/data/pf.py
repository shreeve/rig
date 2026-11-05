import sys,re,collections
maps=[]; c=collections.Counter()
for line in open(sys.argv[1]):
    if "PERF_RECORD_MMAP" in line:
        m=re.search(r"\[(0x[0-9a-f]+)\((0x[0-9a-f]+)\).*\]: (\S+) (\S+)",line)
        if m: a=int(m.group(1),16); maps.append((a,a+int(m.group(2),16),m.group(3),m.group(4).split("/")[-1]))
        continue
    f=line.split()
    try: addr=int(f[0],16)
    except: continue
    w="heap"
    for lo,hi,prot,name in maps:
        if lo<=addr<hi: w="bin-ro" if name=="bin" and prot=="r--p" else ("heap" if name in ("//anon","anon") and prot=="rw-p" else "other"); break
    d="decode" if f[-1]=="ast.decode_bound_file" else "rest"
    c[d+"/"+w]+=1
n=sum(c.values())
print(n, " ".join("%s=%d"%kv for kv in sorted(c.items())))
