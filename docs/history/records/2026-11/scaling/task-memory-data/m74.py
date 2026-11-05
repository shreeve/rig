# m74.py < perf script (comm pid/tid time event trace): per run (pid), each trig thread's CPU
# (task-clock samples x 2 ms), its time in madvise by behavior, and its span; the critical
# thread is the one whose last sample is latest.
import sys, re, collections, statistics as st
P = 2.0  # ms per task-clock sample
cpu = collections.Counter(); first = {}; last = {}; mad = collections.defaultdict(collections.Counter)
madn = collections.defaultdict(collections.Counter); enter = {}; pidstart = {}; pidend = {}
for l in sys.stdin:
    m = re.match(r'\s*(\S+)\s+(\d+)/(\d+)\s+([\d.]+):\s+(\S+):\s*(.*)', l)
    if not m: continue
    comm, pid, tid, t, ev, rest = m.groups(); t = float(t) * 1000
    if comm != 'trig': continue
    k = (pid, tid)
    pidstart.setdefault(pid, t); pidend[pid] = t
    first.setdefault(k, t); last[k] = t
    if ev == 'task-clock': cpu[k] += 1
    elif ev.endswith('enter_madvise'):
        b = int(re.search(r'behavior: (0x[0-9a-f]+)', rest).group(1), 16); enter[k] = (t, b)
    elif ev.endswith('exit_madvise') and k in enter:
        t0, b = enter.pop(k); mad[k][b] += t - t0; madn[k][b] += 1
names = {23: 'POPULATE_WRITE', 14: 'HUGEPAGE', 15: 'NOHUGEPAGE', 4: 'DONTNEED'}
rows = collections.defaultdict(list)
for pid in pidstart:
    ths = [k for k in cpu if k[0] == pid]
    if not ths: continue
    crit = max(ths, key=lambda k: last[k])
    tot_cpu = sum(cpu[k] for k in ths) * P
    tot_pop = sum(mad[k][23] for k in ths)
    rows['wall ms'].append(pidend[pid] - pidstart[pid])
    rows['all threads: CPU ms'].append(tot_cpu)
    rows['all threads: populate ms'].append(tot_pop)
    rows['all threads: populate % of CPU'].append(100 * tot_pop / tot_cpu)
    rows['all threads: madvise calls'].append(sum(sum(madn[k].values()) for k in ths))
    rows['critical: CPU ms'].append(cpu[crit] * P)
    rows['critical: span ms'].append(last[crit] - first[crit])
    rows['critical: populate ms'].append(mad[crit][23])
    rows['critical: populate calls'].append(madn[crit][23])
    rows['critical: populate % of its CPU'].append(100 * mad[crit][23] / max(1, cpu[crit] * P))
    rows['critical: other madvise ms'].append(sum(v for b, v in mad[crit].items() if b != 23))
    # populate done after the first other checker thread ended: the part idle workers could take
    others_end = sorted(last[k] for k in ths if k != crit and cpu[k] * P > 20)
    rows['critical: CPU ms after first other thread ends'].append(0 if not others_end else (last[crit] - others_end[0]))
for k, v in rows.items():
    print(f'{k:52s} median {st.median(v):9.2f}  min {min(v):9.2f}  max {max(v):9.2f}  (n={len(v)})')
