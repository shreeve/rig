# tlbsrc.py KALLSYMS < perf script of tlb:tlb_flush -g: the program's flushes by reason and by the kernel path that made them.
import sys, re, bisect
from collections import Counter
KA, KN = [], []
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) >= 3 and f[1] in 'tTwW': KA.append(int(f[0], 16)); KN.append(f[2])
o = sorted(range(len(KA)), key=lambda i: KA[i]); KA = [KA[i] for i in o]; KN = [KN[i] for i in o]
def ks(x):
    i = bisect.bisect_right(KA, x) - 1
    return KN[i] if i >= 0 else '?'
PATHS = [('sysvec_call_function', 'received IPI'),
         ('wp_page_copy|do_wp_page', 'write fault replacing a read-only page (zero page COW)'),
         ('madvise_dontneed|zap_page_range|madvise_free', 'madvise DONTNEED/FREE'),
         ('__x64_sys_mremap|move_page_tables|move_vma', 'mremap'),
         ('__x64_sys_munmap|__vm_munmap|unmap_region', 'munmap'),
         ('madvise_collapse|khugepaged|collapse_huge', 'huge page collapse'),
         ('__x64_sys_madvise', 'madvise (other advice)'),
         ('__x64_sys_mprotect|change_protection', 'mprotect'),
         ('migrate|numa', 'migration'),
         ('exit_mmap|do_exit', 'exit'),
         ('handle_mm_fault|exc_page_fault', 'page fault (other)'),
         ('flush_tlb_func', 'flush_tlb_func, no sender found')]
c = Counter(); sig = Counter(); tot = 0; cur = None; frames = []
def flush():
    global tot
    if cur is None: return
    comm, reason = cur
    if comm in ('bash', 'setpriv', 'taskset', 'env', 'perf'): return
    names = [ks(x) for x in frames if x >= 0xffff000000000000]
    path = 'other'
    for pat, name in PATHS:
        if any(re.search(pat, n) for n in names): path = name; break
    c[(reason, path)] += 1; tot += 1
    if path == 'other': sig[' < '.join(names[2:7])] += 1
for line in sys.stdin:
    if not line.strip(): flush(); cur = None; frames = []; continue
    if not line.startswith((' ', '\t')):
        m = re.match(r'\s*(.+?)\s+\d+\s+\[\d+\].*reason=(.*)$', line)
        cur = (m.group(1), m.group(2).strip()) if m else None; continue
    m = re.match(r'\s+([0-9a-f]+)\s', line)
    if m: frames.append(int(m.group(1), 16))
flush()
print(f'{tot} flushes')
for (r, p), n in c.most_common(): print(f'{100*n/tot:6.1f}%  {n:7d}  {r:28s} {p}')
for s, n in sig.most_common(5): print('   other:', n, s)
