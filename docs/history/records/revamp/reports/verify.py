import re,subprocess,sys
ok=True
for f in sys.argv[1:]:
    exp=[l[len('# error: '):].rstrip('\n') for l in open(f) if l.startswith('# error: ')]
    r=subprocess.run(['bin/rig','check',f],capture_output=True,text=True)
    out=r.stdout+r.stderr
    diags=re.findall(r'^\S+?:(\d+):(\d+): error: (.*)$',out,re.M)
    bad=[]
    for e in exp:
        m=re.match(r'(\d+):(\d+): (.*)',e)
        if m: hit=any(d[0]==m[1] and d[1]==m[2] and m[3] in d[2] for d in diags)
        else: hit=any(e in d[2] for d in diags)
        if not hit: bad.append(e)
    extra=[d for d in diags if not any((re.match(r'(\d+):(\d+): (.*)',e) and (lambda m:d[0]==m[1] and d[1]==m[2] and m[3] in d[2])(re.match(r'(\d+):(\d+): (.*)',e))) or (not re.match(r'\d+:\d+: ',e) and e in d[2]) for e in exp)]
    status='OK' if r.returncode!=0 and not bad else 'FAIL'
    if status=='FAIL': ok=False
    print(status,f,'exit',r.returncode,'missing',bad,'unexpected',extra)
