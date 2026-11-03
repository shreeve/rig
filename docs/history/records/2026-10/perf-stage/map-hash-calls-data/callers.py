import sys,gzip,collections,re
d,pat=sys.argv[1],sys.argv[2]
c=collections.Counter(); tot=0
for l in gzip.open(d+'/edges.trig.txt.gz','rt'):
    f=[x.strip() for x in l.split('|')]
    if len(f)<3: continue
    try: n=int(f[0])
    except: continue
    tot+=n
    if re.search(pat,f[2]) and not re.search(pat,f[1]): c[(f[1],f[2])]+=n
s=sum(c.values())
print('%s: %d sampled call edges into /%s/ (%.2f%% of all sampled calls)'%(d,s,pat,100*s/tot))
for (a,b),n in c.most_common(int(sys.argv[3]) if len(sys.argv)>3 else 12): print('  %5.1f%% %s -> %s'%(100*n/s,a[:90],b[:60]))
