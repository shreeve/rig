#!/usr/bin/env python3
"""Stage the hunks of `git diff -U1 FILE` whose text contains any of the given keywords."""
import subprocess, sys
os_file = sys.argv[1]; keys = sys.argv[2:]
repo = '/Users/shreeve/Data/Code/rig-rv-tc'
d = subprocess.run(['git','diff','-U1',os_file], cwd=repo, capture_output=True, text=True).stdout
lines = d.splitlines(keepends=True)
head = []; hunks = []; cur = None
for l in lines:
    if l.startswith('@@'):
        cur = [l]; hunks.append(cur)
    elif cur is None: head.append(l)
    else: cur.append(l)
idx = {int(k[1:]) for k in keys if k.startswith('#')}
sel = [h for i, h in enumerate(hunks) if i in idx or any(k in ''.join(h) for k in keys if not k.startswith('#'))]
if '--list' in keys:
    for i,h in enumerate(hunks): print(i, ''.join(h)[:300]); 
    sys.exit()
patch = ''.join(head) + ''.join(''.join(h) for h in sel)
r = subprocess.run(['git','apply','--cached','--recount','-'], cwd=repo, input=patch, text=True, capture_output=True)
print(f"staged {len(sel)}/{len(hunks)} hunks", r.stderr)
