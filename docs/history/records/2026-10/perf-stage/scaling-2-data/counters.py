#!/usr/bin/env python3
# counters.py counters.txt: medians per project, variant and n of
# counters.sh's perf stat lines, with derived rates.
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if 'round=' not in line: continue
    parts = line.split(); proj = parts[0]
    kv = dict(p.split('=', 1) for p in parts[1:] if '=' in p)
    rows[(proj, kv['n'], kv['v'])].append({k: float(v) for k, v in kv.items() if k not in ('v', 'n')})
cols = [('wall ms', lambda d: d['duration_time'] / 1e6), ('task ms', lambda d: d['task-clock']),
        ('ucyc G', lambda d: d['cyclesu'] / 1e9), ('ins G', lambda d: d['instructionsu'] / 1e9),
        ('CPI', lambda d: d['cyclesu'] / d['instructionsu']),
        ('LLCmiss M', lambda d: d['longest_lat_cache.miss'] / 1e6), ('LLCref M', lambda d: d['longest_lat_cache.reference'] / 1e6),
        ('dTLBmiss M', lambda d: d['dTLB-load-misses'] / 1e6), ('memstall G', lambda d: d['mem_bound_stalls_load.all'] / 1e9),
        ('pgwalk G', lambda d: d['ld_head.pgwalk_at_ret'] / 1e9), ('faults K', lambda d: d['page-faults'] / 1e3),
        ('tlbflush', lambda d: d['tlb:tlb_flush']), ('munmap', lambda d: d['syscalls:sys_enter_munmap']),
        ('madvise', lambda d: d['syscalls:sys_enter_madvise']), ('mmap', lambda d: d['syscalls:sys_enter_mmap']),
        ('mremap', lambda d: d['syscalls:sys_enter_mremap']), ('IPI', lambda d: d['irq_vectors:call_function_entry'] + d['irq_vectors:call_function_single_entry']),
        ('mem MiB', lambda d: d['imc_mib']), ('GB/s', lambda d: d['imc_mib'] / 1024 / (d['duration_time'] / 1e9))]
for proj in ('ts-pattern', 'zod3'):
    print(f'\n{proj}')
    print(f"{'n':>4} {'v':5} " + ' '.join(f'{c:>10}' for c, _ in cols))
    for n in ('1', '4on1', '4'):
        for v in ('t773', 't2c0', 'tsgo', 'tsdef'):
            rs = rows.get((proj, n, v))
            if not rs: continue
            print(f"{n:>4} {v:5} " + ' '.join(f'{st.median([f(r) for r in rs]):10.3f}' for _, f in cols))
