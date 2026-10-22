# Insert a sigil where a diagnostic matching PATTERN points, in .rig files.
import os, re, subprocess, sys
ROOT = '/Users/shreeve/Data/Code/rig-sc4'
RIG = ROOT + '/bin/rig'
pattern = re.compile(sys.argv[1])   # regex over the message
insert = sys.argv[2]                # text to insert at the column
targets = sys.argv[3:]
diag = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$')

def entries():
    for t in targets:
        for dirpath, dirs, files in os.walk(os.path.join(ROOT, t)):
            if os.path.exists(os.path.join(dirpath, 'main.rig')) and dirpath != os.path.join(ROOT, t):
                yield os.path.join(dirpath, 'main.rig'); dirs[:] = []; continue
            for f in files:
                if f.endswith('.rig'): yield os.path.join(dirpath, f)

changed = set()
for entry in sorted(set(entries())):
    for _ in range(50):
        r = subprocess.run([RIG, 'check', entry], capture_output=True, text=True, cwd=os.path.dirname(entry))
        fixes = []
        for line in (r.stdout + r.stderr).splitlines():
            m = diag.match(line)
            if m and pattern.search(m.group(4)):
                path = m.group(1)
                if not os.path.isabs(path): path = os.path.join(os.path.dirname(entry), path)
                fixes.append((os.path.normpath(path), int(m.group(2)), int(m.group(3))))
        if not fixes: break
        fixes = sorted(set(fixes), key=lambda f: (f[0], f[1], -f[2]))
        byfile = {}
        for p, l, c in fixes: byfile.setdefault(p, []).append((l, c))
        for p, locs in byfile.items():
            lines = open(p).read().split('\n')
            for l, c in sorted(locs, key=lambda x: (x[0], -x[1])):
                s = lines[l-1]
                lines[l-1] = s[:c-1] + insert + s[c-1:]
            open(p, 'w').write('\n'.join(lines))
            changed.add(p)
for p in sorted(changed): print(p)
