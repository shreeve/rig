import json,sys,collections,re
rs=[json.loads(l) for l in open(sys.argv[1]+'/results.jsonl')]
c=collections.Counter(r['outcome'] for r in rs)
print(c)
for r in rs:
  if r['outcome'] not in ('ok','rejected','ok_panic','checked','rejected_unexpected'):
    print('---',r['id'],r['outcome'],r.get('area'))
    if r['outcome']=='WRONG_OUTPUT':
      e=r.get('expected','').splitlines(); o=r.get('stdout','').splitlines()
      for i,(a,b) in enumerate(zip(e+['<EOF>']*len(o),o+['<EOF>']*len(e))):
        if a!=b: print('  line',i,'exp',a,'| got',b); break
    else:
      err=r.get('stderr') or r.get('err','')
      m=[l for l in err.splitlines() if 'error' in l or 'panic' in l or 'leak' in l]
      print('  ', '\n   '.join(m[:3]))
