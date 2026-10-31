#!/usr/bin/env python3
"""mem.py FILE...: strace -e trace=memory lines summed by call and advice:
count and bytes."""
import sys, re, collections
for path in sys.argv[1:]:
    c = collections.Counter(); b = collections.Counter()
    for line in open(path):
        m = re.match(r'\d+\s+(\w+)\((.*)\)\s+=', line)
        if not m: continue
        name, args = m[1], [a.strip() for a in m[2].split(',')]
        key = name; size = 0
        if name == 'mmap': size = int(args[1]); key += ' ' + args[3]
        elif name == 'munmap': size = int(args[1])
        elif name == 'madvise': size = int(args[1]); key += ' ' + args[2]
        elif name == 'mremap': size = int(args[2]) - int(args[1])
        c[key] += 1; b[key] += size
    print(path)
    for k in sorted(c, key=lambda k: -b[k]):
        print(f'  {c[k]:5d} calls {b[k] / 2**20:10.1f} MiB  {k}')
