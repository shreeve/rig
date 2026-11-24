#!/usr/bin/env python3
# rigloc.py: map a helper name (module.Obj.fn as the profile names it) to its Rig file:line in Trig.
import os, re, glob
T = os.path.expanduser('~/Data/Code/trig/src'); R = os.path.expanduser('~/Data/Code/rig/std')
_idx = None
def index():
    global _idx
    if _idx is not None: return _idx
    _idx = {}
    files = glob.glob(T + '/*/*.rig') + glob.glob(R + '/*.rig')
    for f in files:
        mod = os.path.basename(os.path.dirname(f)) if f.startswith(T) else '__rig_std_' + os.path.basename(f)[:-4]
        obj = None
        for no, line in enumerate(open(f, errors='replace'), 1):
            m = re.match(r'^(?:pub )?obj (\w+)', line)
            if m: obj = m.group(1)
            elif re.match(r'^\S', line) and not line.startswith('#'): obj = None if not line.startswith(('pub obj', 'obj')) else obj
            m = re.match(r'^(\s*)(?:pub )?(?:inline |called )?(?:fun|sub) (?:(\w+)\.)?(\w+)\(', line)
            if m:
                o = m.group(2) or (obj if m.group(1) else None)
                key = '%s.%s%s' % (mod, (o + '.') if o else '', m.group(3))
                _idx.setdefault(key, '%s:%d' % (os.path.relpath(f, T if f.startswith(T) else os.path.dirname(R)), no))
    return _idx
def loc(helper): return index().get(helper, '')
if __name__ == '__main__':
    import sys
    for h in sys.argv[1:]: print(h, loc(h))
