# apply.py FILE EDITS.py : EDITS defines list E of (old, new); each old must occur exactly once
import sys
f, e = sys.argv[1], sys.argv[2]
s = open(f).read()
ns = {}
exec(open(e).read(), ns)
bad = 0
for i, (old, new) in enumerate(ns['E']):
    c = s.count(old)
    if c != 1:
        print(f"edit {i}: found {c} times: {old[:80]!r}"); bad += 1; continue
    s = s.replace(old, new)
if bad: sys.exit(1)
open(f, 'w').write(s)
print("ok", len(ns['E']))
