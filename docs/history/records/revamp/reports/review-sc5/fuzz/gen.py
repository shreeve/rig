import random, subprocess, sys
toks = ['a','b','x','1','2.5','"s"','<','>','+','-','*','?','!','|','~','(',')','[',']','.','.red',',','=','=!','??','+%','*%','-%','<<','>>','f','print','[2]','Int','U128','?Int','\n  ','\n    ',' ','(',')','||','if','else','and','not','catch','@sizeOf','#c\n  ','\\\n','%','/','==','!=',':','->','=>']
random.seed(int(sys.argv[1]))
crashes=0
acc=0
for i in range(int(sys.argv[2])):
    n=random.randint(1,14)
    body=''.join(random.choice(toks)+random.choice(['',' ']) for _ in range(n))
    src="fun f(a: Int) -> Int\n  a\n\nsub main()\n  a = 1\n  b = 2\n  x = 3\n  "+body+"\n  print(a, b, x)\n"
    fn='cur_%s.rig'%sys.argv[1]
    open(fn,'w').write(src)
    p=subprocess.run(['/Users/shreeve/Data/Code/rig-sc5/bin/rig','check',fn],capture_output=True,timeout=30)
    out=(p.stdout+p.stderr).decode(errors='replace')
    if p.returncode==0:
        acc+=1
        open('acc_%s_%d.rig'%(sys.argv[1],i),'w').write(src)
    if p.returncode<0 or 'panic' in out or 'reached unreachable' in out or 'Segmentation' in out or (p.returncode!=0 and ': error' not in out and 'error:' not in out):
        crashes+=1
        open('crash_%s_%d.rig'%(sys.argv[1],i),'w').write(src)
        print('CRASH', i, p.returncode, out[:300])
print('done', crashes, 'accepted', acc)
