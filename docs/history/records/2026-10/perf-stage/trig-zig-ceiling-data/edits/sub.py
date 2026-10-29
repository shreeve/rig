import sys
def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    if n != count: sys.exit(f'{path}: {n} matches, want {count}: {old[:80]!r}')
    open(path, 'w').write(s.replace(old, new))
