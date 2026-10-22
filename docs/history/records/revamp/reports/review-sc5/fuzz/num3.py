import random, subprocess, sys
random.seed(int(sys.argv[1]))
types={'U8':(8,False),'I8':(8,True),'U16':(16,False),'I32':(32,True),'Int':(64,True),'U64':(64,False),'I128':(128,True),'U128':(128,False)}
ops=['+','-','*','/','%','+%','-%','*%','<<','>>','&','|','^']
class Ovf(Exception): pass
def rng(t):
    b,s=types[t]
    return (-(1<<(b-1)),(1<<(b-1))-1) if s else (0,(1<<b)-1)
def fit(t,v):
    lo,hi=rng(t)
    if v<lo or v>hi: raise Ovf()
    return v
def wrap(t,v):
    b,s=types[t]; v&=(1<<b)-1
    if s and v>=(1<<(b-1)): v-=1<<b
    return v
def atom(t):
    r=random.random()
    lo,hi=rng(t)
    if r<0.4:
        c=random.choice([0,1,2,3,7,100,127,128,255,256,65535,4294967296,9223372036854775807,-1,-128])
        if c<lo or c>hi: c=abs(c)%(hi+1) if hi>0 else 0
        return str(c),c
    if r<0.7:
        m=random.choice(['min','max']); return t+'.'+m, (lo if m=='min' else hi)
    if r<0.85: return 'K',3
    return 'v',5
def expr(t,d):
    if d==0 or random.random()<0.25: return atom(t)
    op=random.choice(ops)
    a,av=expr(t,d-1)
    if op in ('<<','>>'):
        n=random.choice([0,1,3,7,8,15,31,63,64,100,126,127])
        b,bv=str(n),n
    else:
        b,bv=expr(t,d-1)
    return '('+a+' '+op+' '+b+')', (op,av,bv)
def ev(t,x):
    if isinstance(x,int): return x
    op,a,b=x; a=ev(t,a); b=ev(t,b)
    bits=types[t][0]
    if op=='+': return fit(t,a+b)
    if op=='-': return fit(t,a-b)
    if op=='*': return fit(t,a*b)
    if op=='+%': return wrap(t,a+b)
    if op=='-%': return wrap(t,a-b)
    if op=='*%': return wrap(t,a*b)
    if op in ('/','%'):
        if b==0: raise Ovf()
        q=abs(a)//abs(b); q= q if (a>=0)==(b>=0) else -q
        if op=='/': return fit(t,q)
        return a-b*q
    if op=='<<':
        if b>=bits: raise Ovf()
        r=a<<b
        if wrap(t,r)!=r: raise Ovf()
        return r
    if op=='>>':
        if b>=bits: raise Ovf()
        return a>>b
    if op=='&': return a&b
    if op=='|': return a|b
    if op=='^': return a^b
bad=0; tested=0
for i in range(int(sys.argv[2])):
    t=random.choice(list(types))
    e,x=expr(t,random.randint(1,3))
    try: exp=str(ev(t,x))
    except Ovf: exp=None
    src="K: %s = 3\n\nsub main()\n  v: %s = 5\n  x: %s = %s\n  print(x, v, K)\n"%(t,t,t,e)
    fn='m_%s.rig'%sys.argv[1]
    open(fn,'w').write(src)
    p=subprocess.run(['/Users/shreeve/Data/Code/rig-sc5/bin/rig','run',fn],capture_output=True,timeout=120)
    out=(p.stdout+p.stderr).decode(errors='replace')
    got=p.stdout.decode().split(' ')[0] if p.returncode==0 else None
    tested+=1
    if got!=exp:
        # rejected where expected overflow is fine
        if exp is None and got is None: continue
        bad+=1
        print('MISMATCH',t,e,'expected',exp,'got',got, [l for l in out.splitlines() if 'error' in l or 'panic' in l][:1])
print('done',bad,tested)
