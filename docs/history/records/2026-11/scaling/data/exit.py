# exit.py < perf script -f of exit.*.data: per run, ms from the program's exit_group to the
# shell's wait4 returning it (the kernel tearing the process down), and TLB flushes in the run.
import sys, re, statistics as st
ev = []
for line in sys.stdin:
    m = re.match(r'\s*(.+?)\s+(\d+)\s+\[\d+\]\s+([\d.]+):\s+(\S+):\s*(.*)$', line)
    if m: ev.append((float(m.group(3)), m.group(1), m.group(4), m.group(5)))
ev.sort()
SH = ('bash', 'setpriv', 'taskset', 'env', 'perf')
runs = []; t_exit = None; fl = 0; fl_exit = 0
for ts, comm, name, rest in ev:
    if name.startswith('tlb:tlb_flush') and comm not in SH:
        fl += 1
        if t_exit is not None: fl_exit += 1
    elif name.startswith('syscalls:sys_enter_exit_group') and comm not in SH and t_exit is None:
        t_exit = ts
    elif name.startswith('syscalls:sys_exit_wait4') and comm == 'bash' and t_exit is not None:
        m = re.search(r'0x([0-9a-f]+)', rest)
        if m and int(m.group(1), 16) > 0:
            runs.append((1000 * (ts - t_exit), fl, fl_exit)); t_exit = None; fl = 0; fl_exit = 0
if runs:
    print('exit to reaped, ms: ' + ' '.join(f'{r[0]:.1f}' for r in runs) + f'  median {st.median(r[0] for r in runs):.1f}')
    print(f'TLB flushes per run, median: {st.median(r[1] for r in runs)} (in the exit: {st.median(r[2] for r in runs)})')
