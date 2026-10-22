# Insert `insert` where diagnostics matching PATTERN point, in ```rig blocks of md files.
import os, re, subprocess, sys, tempfile, shutil
ROOT = '/Users/shreeve/Data/Code/rig-sc4'
RIG = ROOT + '/bin/rig'
pattern = re.compile(sys.argv[1])
insert = sys.argv[2]
files = sys.argv[3:]
diag = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$')

def blocks(lines):
    i = 0
    out = []
    while i < len(lines):
        m = re.match(r'^```rig(.*)$', lines[i])
        if m:
            info = m.group(1).strip()
            j = i + 1
            while lines[j] != '```': j += 1
            out.append((i, j, info))
            i = j
        i += 1
    return out

for f in files:
    path = os.path.join(ROOT, f)
    for _ in range(30):
        lines = open(path).read().split('\n')
        fixes = []
        modules = []
        for (start, end, info) in blocks(lines):
            body = lines[start+1:end]
            if info.startswith('file='):
                modules.append((info[5:], body)); continue
            if info == 'fragment': modules = []; continue
            d = tempfile.mkdtemp()
            for name, b in modules: open(os.path.join(d, name), 'w').write('\n'.join(b) + '\n')
            modules = []
            main = os.path.join(d, 'main.rig')
            open(main, 'w').write('\n'.join(body) + '\n')
            r = subprocess.run([RIG, 'check', 'main.rig'], capture_output=True, text=True, cwd=d)
            for line in (r.stdout + r.stderr).splitlines():
                m = diag.match(line)
                if m and pattern.search(m.group(4)) and os.path.basename(m.group(1)) == 'main.rig':
                    fixes.append((start + int(m.group(2)), int(m.group(3))))
            shutil.rmtree(d)
        if not fixes: break
        for l, c in sorted(set(fixes), key=lambda x: (x[0], -x[1])):
            s = lines[l]
            lines[l] = s[:c-1] + insert + s[c-1:]
        open(path, 'w').write('\n'.join(lines))
        print(f, len(fixes))
