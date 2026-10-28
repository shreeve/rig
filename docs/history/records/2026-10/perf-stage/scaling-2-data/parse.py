#!/usr/bin/env python3
# parse.py DIR: reads timeline.sh's perf script text (DIR/NAME.PROJ.R.txt.gz)
# and prints, per run and as medians over the runs: the wall from exec to
# exit; the head (exec to the first checker's start), the check (to the
# last checker's end) and the tail (to exit); each checker's span and CPU
# time; the time with j of the process's threads running; and, for Trig,
# where the head goes (start to load, load to the first new_checker, the
# checkers made, to the first task).
#
# A Trig checker is known by its task's k and its fiber's stack (each
# check_source_file's self is the task's sp less a constant), so its CPU
# time is what its thread ran while it was that thread's current checker,
# also when several checkers share one core. A tsrs checker is its thread,
# named checker-k; tsrs makes them again for each pass, so a checker's
# time is that of every thread of its name during the check.
import gzip, re, sys, os, glob, statistics as st, collections, json
LINE = re.compile(r'^\s*(.*?)\s+(-?\d+)/(-?\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s*(.*)$')
SW = re.compile(r'^(.*):(-?\d+) \[(-?\d+)\] (\S+) ==> (.*):(-?\d+) \[(-?\d+)\]')
KV = re.compile(r'(\w+)=(\S+)')

def parse(path):
    ev = []
    for raw in gzip.open(path, 'rt', errors='replace'):
        m = LINE.match(raw)
        if m: ev.append((float(m[5]), m[1], int(m[2]), int(m[3]), int(m[4]), m[6], m[7]))
    ev.sort(key=lambda e: e[0])
    # The process: the exec of Trig or tsrs (not taskset, nor another
    # program that ran on these cores meanwhile).
    pid = t0 = None
    for t, comm, p, tid, cpu, name, tr in ev:
        if name == 'sched:sched_process_exec' and re.search(r'filename=\S*(trig|tsrs)', tr):
            pid, t0 = p, t
    tids = {tid for _, _, p, tid, *_ in ev if p == pid and tid > 0}
    tend = max(t for t, comm, p, tid, cpu, name, tr in ev if p == pid and name in ('sched:sched_process_exit', 'syscalls:sys_enter_exit_group'))
    comm_of, runs, oncpu = {}, collections.defaultdict(list), {}
    probes, writes = [], []
    final_comm = {}
    for t, comm, p, tid, cpu, name, tr in ev:
        if p == pid: comm_of[tid] = comm
        if name == 'sched:sched_process_exit' and p == pid:
            m = re.search(r'comm=(\S+)', tr)
            if m: final_comm[tid] = m[1]
        if name == 'sched:sched_switch':
            m = SW.match(tr)
            if not m: continue
            prev, nxt = int(m[2]), int(m[6])
            if prev in tids:
                comm_of[prev] = m[1]
                if prev in oncpu: runs[prev].append((oncpu.pop(prev), t))
            if nxt in tids:
                oncpu[nxt] = t
        elif p == pid and name in ('syscalls:sys_enter_write', 'syscalls:sys_enter_writev') and 'fd: 0x00000001,' in tr:
            writes.append(t)
        elif p == pid and ':' in name and name.split(':')[0].startswith('p'):
            probes.append((t, tid, name.split(':')[1].split('_', 1)[1], dict(KV.findall(tr))))
    for tid, s in oncpu.items(): runs[tid].append((s, tend))
    comm_of.update(final_comm)
    # The first run of each thread starts at its first switch-in; a thread
    # running when the record started (the exec'ing one) starts at t0.
    first_in = {tid: min(a for a, b in r) for tid, r in runs.items() if r}
    return dict(pid=pid, t0=t0, tend=tend, runs=runs, probes=probes, comm=comm_of, write=min(writes) if writes else None)

def overlap(runs, a, b):
    return sum(max(0, min(y, b) - max(x, a)) for x, y in runs)

def concurrency(allruns, a, b):
    pts = []
    for r in allruns:
        for x, y in r:
            x, y = max(x, a), min(y, b)
            if y > x: pts += [(x, 1), (y, -1)]
    pts.sort()
    hist = collections.Counter(); cur = 0; last = a
    for x, d in pts:
        hist[cur] += x - last; cur += d; last = x
    hist[cur] += b - last
    return hist

def trig(d):
    P = d['probes']
    sp = {}
    for t, tid, n, kv in P:
        if n == 'task': sp[int(kv['k'])] = (int(kv['sp']), t)
    selfs = {int(kv['self']) for t, tid, n, kv in P if n == 'csf'}
    # The constant sp - self, the one every k shares.
    diffs = collections.Counter(s - x for s, _ in sp.values() for x in selfs if 0 < s - x < 1 << 20)
    if diffs:
        c = diffs.most_common(1)[0][0]
        k_of_self = {s - c: k for k, (s, _) in sp.items()}
    else:  # one checker: no task; its checks run on the main fiber
        k_of_self = {x: 0 for x in selfs}
    cur, last = {}, {}
    cpu = collections.Counter(); start = {}; end = {}; files = collections.defaultdict(list)
    runs = d['runs']
    def charge(tid, t):
        if tid in cur and cur[tid] is not None:
            cpu[cur[tid]] += overlap(runs[tid], last[tid], t)
        last[tid] = t
    open_file = {}
    # A stack belongs to checker k when it lies below k's task entry sp,
    # within the fiber's stack (fibers' stacks are tens of MiB apart).
    def k_of_stack(x):
        best = None
        for k, (s0, _) in sp.items():
            if 0 <= s0 - x < 8 << 20 and (best is None or s0 - x < sp[best][0] - x): best = k
        return best
    switched = set()
    for t, tid, n, kv in P:
        if n not in ('task', 'csf', 'csfdone', 'taskend', 'sw'): continue
        charge(tid, t)
        if n == 'sw':
            # Before the first task, sp is unknown; switches then are the head's.
            cur[tid] = k_of_stack(int(kv['to'])) if sp else None
            switched.add(tid)
        elif n == 'task':
            k = int(kv['k']); cur[tid] = k; start[k] = t
        elif n == 'csf':
            k = k_of_self.get(int(kv['self'])); cur[tid] = k
            open_file[k] = (int(kv['file']), t)
        elif n == 'csfdone':
            k = cur.get(tid)
            if k in open_file:
                f, a = open_file.pop(k); files[k].append((f, t - a))
        elif n == 'taskend':
            k = cur.get(tid); end[k] = t; cur[tid] = None
    loads = [t for t, tid, n, kv in P if n == 'load']
    newck = [t for t, tid, n, kv in P if n == 'newck']
    nsw = sum(1 for t, tid, n, kv in P if n == 'sw')
    out = dict(start=start, end=end, cpu=dict(cpu), files={k: v for k, v in files.items()}, switches=nsw)
    out['head_parts'] = dict(to_load=loads[0] - d['t0'] if loads else None,
                            load_to_newck=(newck[0] - loads[0]) if loads and newck else None,
                            newck=(newck[-1] - newck[0]) if newck else None,
                            to_task=(min(start.values()) - newck[-1]) if newck and start else None)
    return out

def tsrs(d):
    start, end, cpu = {}, {}, collections.Counter()
    for tid, comm in d['comm'].items():
        m = re.match(r'checker-(\d+)', comm or '')
        if not m or not d['runs'][tid]: continue
        k = int(m[1])
        r = d['runs'][tid]
        busy = sum(b - a for a, b in r)
        if busy < 0.001: continue  # the short later passes are charged below
        start[k] = min(start.get(k, 9e18), r[0][0]); end[k] = max(end.get(k, 0), r[-1][1])
    if not start: return dict(start={}, end={}, cpu={})
    a, b = min(start.values()), max(end.values())
    for tid, comm in d['comm'].items():
        m = re.match(r'checker-(\d+)', comm or '')
        if m: cpu[int(m[1])] += overlap(d['runs'][tid], a, b)
    return dict(start=start, end=end, cpu=dict(cpu))

def run(path):
    d = parse(path)
    c = trig(d) if os.path.basename(path).startswith('trig') else tsrs(d)
    t0, tend = d['t0'], d['tend']
    if not c['start']:  # one checker: the check is the first file's check to the output
        csf = [t for t, tid, n, kv in d['probes'] if n == 'csf']
        c['start'] = {0: csf[0] if csf else t0}; c['end'] = {0: d['write']}
        c['cpu'] = {0: None}
    a = min(c['start'].values()); b = max(c['end'].values())
    span = {k: c['end'][k] - c['start'][k] for k in c['start'] if k in c['end']}
    conc = concurrency(d['runs'].values(), t0, tend)
    allcpu = sum(sum(y - x for x, y in r) for r in d['runs'].values())
    res = dict(wall=tend - t0, head=a - t0, check=b - a, tail=tend - b, span=span, cpu=c['cpu'],
               to_write=(d['write'] - t0) if d['write'] else None, after_write=(tend - d['write']) if d['write'] else None,
               conc={j: v for j, v in sorted(conc.items())}, task=allcpu)
    if 'head_parts' in c: res['head_parts'] = c['head_parts']
    if 'files' in c: res['files'] = c['files']
    if 'switches' in c: res['switches'] = c['switches']
    return res

def ms(x): return f'{x*1e3:7.1f}' if x is not None else '      -'

if __name__ == '__main__':
    D = sys.argv[1]
    groups = collections.defaultdict(list)
    for p in sorted(glob.glob(f'{D}/*.txt.gz')):
        name, proj, r = os.path.basename(p)[:-7].split('.')
        try: groups[(proj, name)].append(run(p))
        except Exception as e: print('#', p, 'failed:', e)
    allres = {}
    for (proj, name), rs in sorted(groups.items()):
        print(f'\n## {proj} {name} ({len(rs)} runs)')
        for i, r in enumerate(rs):
            ks = sorted(r['span'])
            print(f"run {i+1}: wall {ms(r['wall'])} write {ms(r['to_write'])} exit-after-write {ms(r['after_write'])} head {ms(r['head'])} check {ms(r['check'])} tail {ms(r['tail'])} | span " +
                  ' '.join(f"{k}:{r['span'][k]*1e3:.0f}" for k in ks) + ' | cpu ' + ' '.join(f"{k}:{(r['cpu'].get(k) or 0)*1e3:.0f}" for k in ks) +
                  ' | conc ' + ' '.join(f"{j}:{v*1e3:.0f}" for j, v in r['conc'].items()) +
                  (f" | switches {r['switches']}" if 'switches' in r else '') +
                  (' | head ' + ' '.join(f"{k} {ms(v).strip()}" for k, v in r['head_parts'].items()) if 'head_parts' in r else ''))
        med = lambda f: st.median([f(r) for r in rs])
        ks = sorted(set.intersection(*[set(r['span']) for r in rs]))
        m = dict(wall=med(lambda r: r['wall']), head=med(lambda r: r['head']), check=med(lambda r: r['check']), tail=med(lambda r: r['tail']),
                 span={k: med(lambda r: r['span'][k]) for k in ks}, cpu={k: med(lambda r: r['cpu'].get(k) or 0) for k in ks},
                 to_write=med(lambda r: r['to_write'] or 0), after_write=med(lambda r: r['after_write'] or 0),
                 task=med(lambda r: r['task']))
        if 'head_parts' in rs[0]:
            m['head_parts'] = {h: med(lambda r: r['head_parts'][h] or 0) for h in rs[0]['head_parts']}
        allj = sorted({j for r in rs for j in r['conc']})
        m['conc'] = {j: med(lambda r: r['conc'].get(j, 0)) for j in allj}
        print(f"median: wall {ms(m['wall'])} write {ms(m['to_write'])} exit-after-write {ms(m['after_write'])} head {ms(m['head'])} check {ms(m['check'])} tail {ms(m['tail'])} | span " +
              ' '.join(f"{k}:{v*1e3:.0f}" for k, v in m['span'].items()) + ' | cpu ' + ' '.join(f"{k}:{v*1e3:.0f}" for k, v in m['cpu'].items()) +
              f" | task {m['task']*1e3:.0f} | conc " + ' '.join(f"{j}:{v*1e3:.0f}" for j, v in m['conc'].items()) +
              (' | head ' + ' '.join(f"{k} {v*1e3:.1f}" for k, v in m['head_parts'].items()) if 'head_parts' in m else ''))
        allres[f'{proj} {name}'] = dict(median=m, runs=[{k: v for k, v in r.items() if k != 'files'} for r in rs],
                                        files=[r.get('files') for r in rs])
    json.dump(allres, open(f'{D}/timeline.json', 'w'), default=str)
