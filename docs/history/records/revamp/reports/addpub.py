import subprocess, re, sys, os
rig = '/Users/shreeve/Data/Code/rig-sc5/bin/rig'
for d in sys.argv[1:]:
    for it in range(20):
        r = subprocess.run([rig, 'check', 'main.rig'], cwd=d, capture_output=True, text=True)
        out = r.stdout + r.stderr
        lines = out.splitlines()
        todo = set()
        inpriv = False
        for ln in lines:
            m = re.match(r'^(\S+?):(\d+):(\d+): error: (.*)', ln)
            if m:
                inpriv = ('private' in m.group(4))
                continue
            m = re.match(r'^(\S+?):(\d+):(\d+):\s+note: `\w+` declared here', ln)
            if m and inpriv:
                todo.add((m.group(1), int(m.group(2))))
        if not todo:
            break
        for f, l in todo:
            p = os.path.join(d, f)
            src = open(p).read().split('\n')
            s = src[l-1]
            ind = len(s) - len(s.lstrip(' '))
            if not s.lstrip().startswith('pub '):
                src[l-1] = s[:ind] + 'pub ' + s[ind:]
            open(p,'w').write('\n'.join(src))
    print(d, it)
