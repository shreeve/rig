import collections, statistics, sys
d=collections.defaultdict(list)
C={"pingpong":20000,"echo":100000,"connect":500}
for l in open(sys.argv[1]):
    if l.startswith('#'): break
    r,lab,name,ns=l.split(); d[(name,lab)].append(int(ns))
for k in sorted(d):
    v=sorted(d[k]); print("%-9s %-10s min %7.2f med %7.2f n=%d"%(k[0],k[1],v[0]/C.get(k[0],1)/1e3, statistics.median(v)/C.get(k[0],1)/1e3, len(v)))
