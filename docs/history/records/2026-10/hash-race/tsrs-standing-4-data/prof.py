#!/usr/bin/env python3
"""prof.py DIR: reads diag.sh's sampled profiles (prof.{trig,tsrs}.N.txt.gz),
a sample every 10M cycles on core 1, and splits each run's samples by phase
(Trig: exec to FileLoader.load, to Checker.check_source_file (the check's start), to the first write to stdout,
to exit_group, to the process's exit; tsrs: exec, first write to stdout,
exit_group, exit) and by kind: user (by function), and kernel by what it
serves (page faults by handler, each syscall, exit teardown, exec, other).
Prints per variant the mean samples a run in each, and in ms at the run's
mean cycles a ms; the samples of perf's own setup are left out."""
import sys, gzip, glob, re, collections
D = sys.argv[1]
PERIOD = 10_000_000
def runs(v):
    for p in sorted(glob.glob(f'{D}/prof.{v}.*.txt.gz')):
        yield p
def parse(path):
    evs = []
    cur = None
    for line in gzip.open(path, 'rt', errors='replace'):
        if not line.strip():
            if cur: evs.append(cur); cur = None
            continue
        if not line.startswith('\t') and not line.startswith(' '):
            m = re.match(r'(\S+)\s+(\d+)/(\d+)\s+([\d.]+):\s+(\S+):\s*(.*)', line)
            if not m: continue
            cur = dict(comm=m[1], pid=int(m[2]), tid=int(m[3]), t=float(m[4]), ev=m[5], trace=m[6], chain=[])
        elif cur is not None:
            parts = line.strip().split(None, 2)
            if len(parts) >= 2:
                addr = int(parts[0], 16); sym = parts[1]; dso = parts[2] if len(parts) > 2 else ''
                cur['chain'].append((addr, sym, dso))
    if cur: evs.append(cur)
    return evs
def kind(chain):
    syms = [s for a, s, d in chain if a >= 0xffff000000000000]
    user = [s for a, s, d in chain if a < 0xffff000000000000 and a != 0]
    leaf = user[0] if user else '[unknown]'
    if not syms:
        return 'user', leaf
    js = ' '.join(syms)
    if 'perf_event' in js or 'perf_trace_init' in js or 'perf_try_init' in js or 'uprobe' in js:
        return 'kernel', 'perf (probes, setup)'
    if 'asm_exc_page_fault' in js or 'exc_page_fault' in js:
        if 'clear_huge_page' in js or 'folio_zero_user' in js and 'huge' in js or 'do_huge_pmd' in js:
            return 'kernel', 'fault: huge page'
        if 'filemap_fault' in js or 'do_read_fault' in js or 'filemap_map_pages' in js:
            return 'kernel', 'fault: file'
        if 'do_wp_page' in js or 'wp_page_copy' in js:
            return 'kernel', 'fault: write after zero page'
        return 'kernel', 'fault: anon'
    if 'do_exit' in js or 'do_group_exit' in js:
        return 'kernel', 'exit teardown'
    m = re.search(r'__(?:x64|do)_sys_(\w+)', js)
    if m:
        n = m[1]
        if n in ('execve',): return 'kernel', 'exec'
        return 'kernel', 'sys ' + n
    if 'asm_sysvec' in js or 'irq' in js or 'apic' in js:
        return 'kernel', 'interrupt'
    if 'ret_from_fork' in js or 'schedule_tail' in js:
        return 'kernel', 'thread start'
    return 'kernel', 'other: ' + syms[-1] if syms else 'other'
def analyze(v):
    tot = collections.Counter(); phase = collections.Counter(); phk = collections.Counter()
    userf = collections.Counter(); faultf = collections.Counter(); spans = collections.defaultdict(list)
    n = 0
    for path in runs(v):
        evs = parse(path)
        comm = 'trigprobe' if v == 'trig' else 'tsrs'
        evs = [e for e in evs if e['comm'] == comm or (e['ev'] == 'sched:sched_process_exec' and comm in e['trace'])]
        if not evs: continue
        n += 1
        t0 = min(e['t'] for e in evs if e['ev'] == 'sched:sched_process_exec')
        def first(ev, pred=lambda e: True):
            ts = [e['t'] for e in evs if e['ev'] == ev and pred(e)]
            return min(ts) if ts else None
        tl = first('s4:load'); tn = first('s4:csf')
        tw = min([x for x in [first('syscalls:sys_enter_write', lambda e: 'fd: 0x00000001' in e['trace']), first('syscalls:sys_enter_writev', lambda e: 'fd: 0x00000001' in e['trace'])] if x] or [None])
        tx = first('syscalls:sys_enter_exit_group')
        te = max(e['t'] for e in evs if e['ev'] == 'sched:sched_process_exit') if any(e['ev'] == 'sched:sched_process_exit' for e in evs) else None
        marks = [('start', t0), ('load', tl), ('check', tn), ('out', tw), ('exit_group', tx), ('end', te)]
        marks = [(k, t) for k, t in marks if t is not None]
        for (a, ta), (b, tb) in zip(marks, marks[1:]):
            spans[f'{a}->{b}'].append((tb - ta) * 1e3)
        for e in evs:
            if e['ev'] != 'cpu_core/cycles/': continue
            k, s = kind(e['chain'])
            if s == 'perf (probes, setup)': continue
            ph = 'pre'
            for name, t in marks:
                if e['t'] >= t: ph = name
            tot[k] += 1; phase[ph] += 1; phk[(ph, k)] += 1
            if k == 'user': userf[s] += 1
            else: faultf[s] += 1
    return n, tot, phase, phk, userf, faultf, spans
for v in ['trig', 'tsrs']:
    n, tot, phase, phk, userf, faultf, spans = analyze(v)
    if not n: continue
    ms = lambda c: c * PERIOD / n / 4.75e6  # at 4.75 GHz
    print(f'\n## {v}: {n} runs, {sum(tot.values())/n:.1f} samples a run ({ms(sum(tot.values())):.1f} ms of CPU at 4.75 GHz)')
    print('spans (ms, mean): ' + ', '.join(f'{k} {sum(x)/len(x):.1f}' for k, x in spans.items()))
    print('by phase (samples a run, user / kernel): ' + ', '.join(f'{p} {phk[(p,"user")]/n:.1f}/{phk[(p,"kernel")]/n:.1f}' for p in ['pre', 'start', 'load', 'check', 'out', 'exit_group', 'end'] if phase[p]))
    print(f'user {tot["user"]/n:.1f} ({ms(tot["user"]):.1f} ms), kernel {tot["kernel"]/n:.1f} ({ms(tot["kernel"]):.1f} ms)')
    print('kernel by kind (samples a run, ms):')
    for s, c in faultf.most_common(25):
        print(f'  {c/n:6.2f} {ms(c):6.2f} ms  {s}')
    print('user by function, top 40 (samples a run, ms):')
    for s, c in userf.most_common(40):
        print(f'  {c/n:6.2f} {ms(c):6.2f} ms  {s}')
