#!/usr/bin/env python3
# mm.py DIR: per project and build, summed over mm.sh's runs: mmap,
# munmap, mremap and madvise calls (madvise by advice), TLB flushes by
# reason, and function-call IPIs, by phase (head, check, tail as in
# parse.py), and the Rig or Trig frames nearest the top of each munmap's
# and madvise's user stack.
import gzip, glob, os, re, sys, collections
D = sys.argv[1]
HDR = re.compile(r'^\s*(.*?)\s+(-?\d+)/(-?\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(?:\d+\s+)?(\S+):\s*(.*)$')
REASON = {0: 'task switch', 1: 'remote shootdown', 2: 'local shootdown', 3: 'local mm shootdown', 4: 'remote send IPI'}
ADV = {14: 'HUGEPAGE', 15: 'NOHUGEPAGE', 23: 'POPULATE_WRITE', 4: 'DONTNEED', 8: 'FREE'}
agg = {}
for p in sorted(glob.glob(f'{D}/*.txt.gz')):
    b, proj, r = os.path.basename(p)[:-7].split('.')
    recs = []; cur = None
    for line in gzip.open(p, 'rt', errors='replace'):
        m = HDR.match(line)
        if m and not line.startswith('\t'):
            cur = [float(m[5]), int(m[2]), int(m[3]), m[6], m[7], []]; recs.append(cur); continue
        f = re.match(r'^\s+([0-9a-f]+)\s+(.*)$', line)
        if f and cur is not None: cur[5].append(f[2].split('+0x')[0].strip())
    ex = [(t, pid) for t, pid, tid, ev, tr, st in recs if ev == 'sched:sched_process_exec' and re.search(r'filename=\S*trig', tr)]
    t0, pid = ex[-1]
    tend = max(t for t, pp, tid, ev, tr, st in recs if pp == pid and ev in ('sched:sched_process_exit', 'syscalls:sys_enter_exit_group'))
    tasks = [t for t, pp, tid, ev, tr, st in recs if ev.endswith('_task')]
    ends = [t for t, pp, tid, ev, tr, st in recs if ev.endswith('_taskend')]
    a, bb = min(tasks), max(ends)
    g = agg.setdefault((proj, b), dict(runs=0, c=collections.Counter(), who=collections.Counter()))
    g['runs'] += 1
    for t, pp, tid, ev, tr, st in recs:
        if t < t0 or t > tend: continue
        ph = 'head' if t < a else 'check' if t <= bb else 'tail'
        name = ev.split(':')[-1]
        if pp == pid and name.startswith('sys_enter_m'):
            key = name[len('sys_enter_'):]
            if key == 'madvise':
                adv = int(re.search(r'behavior:\s*(0x[0-9a-f]+)', tr)[1], 16); key += ' ' + ADV.get(adv, str(adv))
            g['c'][(ph, key)] += 1
            frames = [s for s in st if re.match(r'(rig\.|compiler\.|checker\.|binder\.|parser\.|declarations\.|execute\.)', s)]
            if name in ('sys_enter_munmap', 'sys_enter_madvise', 'sys_enter_mremap'):
                g['who'][(ph, key, ' < '.join(frames[:3]) or '?')] += 1
        elif name == 'tlb_flush':
            m2 = re.search(r'reason=(.*) \((\d+)\)', tr)
            g['c'][(ph, 'tlb_flush ' + (REASON.get(int(m2[2]), m2[1]) if m2 else '?'))] += 1
        elif name.startswith('call_function'):
            g['c'][(ph, 'IPI')] += 1
for (proj, b), g in sorted(agg.items()):
    n = g['runs']
    print(f'\n## {proj} {b} ({n} runs; per run)')
    for ph in ('head', 'check', 'tail'):
        print(f'  {ph}: ' + ', '.join(f'{k} {v / n:.0f}' for (p2, k), v in sorted(g['c'].items()) if p2 == ph))
    for (ph, key, w), v in g['who'].most_common(14):
        print(f'    {ph} {key} {v / n:.0f}: {w}')
