# stage.py FILE REGEX...: stage the hunks of FILE's unstaged diff whose text matches any REGEX.
import re, subprocess, sys
f = sys.argv[1]; pats = [re.compile(p) for p in sys.argv[2:]]
d = subprocess.run(['git', 'diff', '-U2', '--', f], capture_output=True, text=True).stdout
lines = d.splitlines(keepends=True)
head = []; hunks = []; cur = None
for l in lines:
    if l.startswith('@@'):
        cur = [l]; hunks.append(cur)
    elif cur is None: head.append(l)
    else: cur.append(l)
sel = [h for h in hunks if any(p.search(''.join(h)) for p in pats)]
print(f, len(sel), 'of', len(hunks))
if sel:
    patch = ''.join(head) + ''.join(''.join(h) for h in sel)
    r = subprocess.run(['git', 'apply', '--cached', '--recount', '-'], input=patch, text=True)
    sys.exit(r.returncode)
