#!/usr/bin/env python3
"""faults.py DIR: every page fault of diag.sh's fault runs, per run: in the
kernel (exec, syscalls) or in user code, and in user code by the function
that touched the page (the leaf; Trig keeps no frame pointer)."""
import sys, gzip, glob, collections
D = sys.argv[1]
for v in ['trig', 'tsrs']:
    c = collections.Counter(); where = collections.Counter(); n = 0; tot = 0
    for p in sorted(glob.glob(f'{D}/faults.{v}.*.txt.gz')):
        n += 1; chain = None
        def flush(ch):
            global tot
            if ch is None: return
            ks = [s for a, s in ch if a >= 0xffff000000000000]
            us = [s for a, s in ch if a < 0xffff000000000000 and a]
            tot += 1
            if ks:
                js = ' '.join(ks)
                k = 'exec' if 'execve' in js else ('kernel: ' + next((s for s in ks if s.startswith('__x64_sys_')), ks[-1]))
                where[k] += 1
            else:
                where['user'] += 1
                c[us[0] if us else '?'] += 1
        for line in gzip.open(p, 'rt', errors='replace'):
            if not line.strip(): flush(chain); chain = None; continue
            if not line[0].isspace():
                flush(chain); chain = [] if 'page-faults' in line else None; continue
            if chain is not None:
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    try: chain.append((int(parts[0], 16), parts[1]))
                    except ValueError: pass
        flush(chain)
    print(f'\n{v}: {n} runs, {tot / n:,.0f} faults a run')
    for k, x in where.most_common(10): print(f'  {x / n:8.0f}  {k}')
    print('  in user code, by function:')
    for k, x in c.most_common(25): print(f'  {x / n:8.0f}  {k}')
