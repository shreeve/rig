import random, subprocess, sys
random.seed(int(sys.argv[1]))
types=['U8','I8','U16','I32','Int','U64','I128','U128']
ops=['+','-','*','/','%','+%','-%','*%','<<','>>','&','|','^']
def atom(t):
    r=random.random()
    if r<0.3: return random.choice(['0','1','2','3','7','100','127','128','255','256','-1','65535','4294967296','9223372036854775807'])
    if r<0.55: return t+'.'+random.choice(['min','max'])
    if False: pass
    if r<0.9: return 'K'
    return 'v'
def expr(t,d):
    if d==0 or random.random()<0.3: return atom(t)
    op=random.choice(ops)
    if op in ('<<','>>'): return '('+expr(t,d-1)+' '+op+' '+random.choice(['0','1','3','7','8','15','31','63','64','100','126','127'])+')'
    return '('+expr(t,d-1)+' '+op+' '+expr(t,d-1)+')'
bad=0
for i in range(int(sys.argv[2])):
    t=random.choice(types)
    e=expr(t,random.randint(1,3))
    ctx=random.choice(['print(%s)','x: '+t+' = %s\n  print(x)','X_CONST'])
    if ctx=='X_CONST':
        src="K: %s = 3\nC: %s = %s\n\nsub main()\n  v: %s = 5\n  print(C, v)\n"%(t,t,e.replace('v','K'),t)
    else:
        src="K: %s = 3\n\nsub main()\n  v: %s = 5\n  %s\n"%(t,t,ctx%e)
    fn='n_%s.rig'%sys.argv[1]
    open(fn,'w').write(src)
    p=subprocess.run(['/Users/shreeve/Data/Code/rig-sc5/bin/rig','check',fn],capture_output=True,timeout=60)
    if p.returncode!=0: continue
    p=subprocess.run(['/Users/shreeve/Data/Code/rig-sc5/bin/rig','run',fn],capture_output=True,timeout=120)
    out=(p.stdout+p.stderr).decode(errors='replace')
    if '.zig:' in out and 'error:' in out and 'panic' not in out:
        bad+=1
        open('zigerr_%s_%d.rig'%(sys.argv[1],i),'w').write(src)
        print('ZIGERR',i,src.replace('\n','|'), [l for l in out.splitlines() if 'error' in l][:1])
print('done',bad)
