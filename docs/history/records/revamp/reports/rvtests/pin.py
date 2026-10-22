import re, subprocess, sys
for f in sys.argv[1:]:
    out = subprocess.run(['bin/rig','check',f],capture_output=True,text=True)
    diags = []
    for line in (out.stdout+out.stderr).splitlines():
        m = re.match(r'^.*\.rig:(\d+:\d+): (error|  note): (.*)$', line)
        if m: diags.append((m.group(1), m.group(2).strip(), m.group(3)))
    src = open(f).read().split('\n')
    changed = False
    for i, l in enumerate(src):
        m = re.match(r'^# error: (.*)$', l)
        if not m or re.match(r'^\d+:\d+: ', m.group(1)): continue
        want = m.group(1)
        hits = [d for d in diags if want in d[2]]
        errs = [d for d in hits if d[1]=='error']
        if len(hits) == 1 or (len(errs) == 1 and len(hits) > 1 and False):
            pos, kind, msg = hits[0]
            src[i] = f'# error: {pos}: {msg}'
            changed = True
        else:
            print(f'SKIP {f}: "{want}" matches {len(hits)}: {hits}')
    if changed:
        open(f,'w').write('\n'.join(src))
        print(f'pinned {f}')
