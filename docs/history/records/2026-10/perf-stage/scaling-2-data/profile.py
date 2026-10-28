#!/usr/bin/env python3
# profile.py DIR: reads profile.sh's text and prints, per project and
# variant, summed over the runs: CPU ms by phase (head: exec to the first
# checker task; check: to the last task's end; tail: to exit; for one
# checker the check ends at the output's writev), each phase's share by
# kind of code (kernel, Rig's allocator, scheduler and tasks, tables,
# memcpy/memset, the rest), and its heaviest leaf symbols and frames.
import gzip, re, sys, glob, os, collections
HDR = re.compile(r'^\s*(.*?)\s+(-?\d+)/(-?\d+)\s+()([\d.]+):\s+(?:(\d+)\s+)?(\S+):\s*(.*)$')
FR = re.compile(r'^\s+([0-9a-f]+)\s+(.*)$')
# E-core cycles per ms of CPU, from time.sh's user cycles over user time
# at four checkers (about 3.5 GHz); for converting samples to ms only.
CYC_PER_MS = 3.5e6
INCL = ['compiler.FileLoader', 'parser.', 'binder.', 'checker.new_checker', 'checker.Checker.check_source_file',
        'compiler.sort_and_deduplicate', 'execute.report', 'dropFields', 'deinit', 'rig.alloc.', 'rig.sched.', 'rig.tasks.',
        'rig.table.', 'munmap', 'exit_mmap', 'do_exit', 'asm_exc_page_fault', 'execute.', 'declarations.CheckerPool.get_global_diagnostics']
def kind(stack):
    ip, sym = stack[0]
    if int(ip, 16) >= 0xffff000000000000: return 'kernel'
    for pre, k in (('rig.alloc', 'rig.alloc'), ('rig.sched', 'rig.sched/tasks'), ('rig.tasks', 'rig.sched/tasks'),
                   ('rig.table', 'rig.table'), ('compiler_rt.mem', 'memcpy/memset'), ('memcpy', 'memcpy/memset'), ('memset', 'memcpy/memset'), ('memmove', 'memcpy/memset')):
        if sym.startswith(pre): return k
    return 'user other'
def read(path):
    samples, marks = [], collections.defaultdict(list)
    cur = None
    for line in gzip.open(path, 'rt', errors='replace'):
        if not line.strip():
            if cur: samples.append(cur) if cur[2] == 'cyc' else None
            cur = None; continue
        m = HDR.match(line)
        if m and not line.startswith('\t'):
            ev = m[7]; t = float(m[5]); pid = int(m[2])
            if 'cycles' in ev: cur = (t, pid, 'cyc', [])
            else:
                cur = None
                marks[ev].append((t, pid, m[8]))
            continue
        f = FR.match(line)
        if f and cur is not None: cur[3].append((f[1], f[2].split('+0x')[0].strip()))
    if cur and cur[2] == 'cyc': samples.append(cur)
    return samples, marks
def phases(marks):
    ex = [(t, p) for t, p, tr in marks['sched:sched_process_exec:'] + marks.get('sched:sched_process_exec', []) if re.search(r'filename=\S*(trig|tsrs)', tr)]
    t0, pid = max(ex) if ex else (None, None)
    def m(name): return [t for k, v in marks.items() if k.rstrip(':').endswith(name) for t, p, tr in v if p == pid]
    tend = max(m('sched_process_exit') + m('sys_enter_exit_group'))
    tasks, ends = m('_task'), m('_taskend')
    wv = [t for k, v in marks.items() if k.rstrip(':').endswith('writev') or k.rstrip(':').endswith('sys_enter_write') for t, p, tr in v if p == pid and 'fd: 0x00000001,' in tr]
    if tasks: a, b = min(tasks), max(ends)
    else:
        csf = m('_csf'); a = min(csf) if csf else t0; b = min(wv) if wv else tend
    return pid, t0, a, b, tend
if __name__ == '__main__':
    D = sys.argv[1]
    agg = {}
    for p in sorted(glob.glob(f'{D}/*.txt.gz')):
        name, proj, r = os.path.basename(p)[:-7].split('.')
        samples, marks = read(p)
        pid, t0, a, b, tend = phases(marks)
        g = agg.setdefault((proj, name), dict(runs=0, ph=collections.Counter(), kind=collections.Counter(), leaf=collections.Counter(), incl=collections.Counter(), dur=collections.Counter()))
        g['runs'] += 1
        g['dur'].update(head=a - t0, check=b - a, tail=tend - b)
        for t, sp, _, st in samples:
            if sp != pid or not st or t < t0: continue
            ph = 'head' if t < a else 'check' if t < b else 'tail'
            g['ph'][ph] += 1; g['kind'][(ph, kind(st))] += 1; g['leaf'][(ph, st[0][1])] += 1
            seen = set()
            for _, s in st:
                for pat in INCL:
                    if pat in s and pat not in seen: seen.add(pat); g['incl'][(ph, pat)] += 1
    for (proj, name), g in sorted(agg.items()):
        n = g['runs']; per = lambda c: c / n * 4e6 / CYC_PER_MS  # a sample is 4M cycles; ms per run
        print(f"\n## {proj} {name}: {n} runs; per run, wall ms by phase: " + ' '.join(f"{k} {v / n * 1e3:.1f}" for k, v in g['dur'].items()))
        for ph in ('head', 'check', 'tail'):
            tot = g['ph'][ph]
            if not tot: continue
            print(f"  {ph}: CPU {per(tot):.1f} ms; " + ', '.join(f"{k} {per(c):.1f}" for (p2, k), c in sorted(g['kind'].items(), key=lambda x: -x[1]) if p2 == ph))
            print('    leaf: ' + '; '.join([f"{s} {per(c):.1f}" for (p2, s), c in g['leaf'].most_common() if p2 == ph][:12]))
            print('    under: ' + '; '.join(f"{pat} {per(c):.1f}" for (p2, pat), c in sorted(g['incl'].items(), key=lambda x: -x[1]) if p2 == ph))
