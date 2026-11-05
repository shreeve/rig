# classify2.py KALLSYMS USERSYMS < perf script -F comm,tid,ip,dso output (callchains):
# share of cycle samples by kind: kernel by entry point, user by Rig runtime part.
import sys, re, bisect
from collections import Counter
def load(path, kernel):
    a, n = [], []
    for line in open(path):
        f = line.split()
        if len(f) < 3: continue
        if kernel and f[1] not in 'tTwW': continue
        a.append(int(f[0], 16)); n.append(f[2])
    o = sorted(range(len(a)), key=lambda i: a[i])
    return [a[i] for i in o], [n[i] for i in o]
KA, KN = load(sys.argv[1], True)
UA, UN = load(sys.argv[2], False) if len(sys.argv) > 2 else ([], [])
def ksym(x):
    i = bisect.bisect_right(KA, x) - 1
    return KN[i] if i >= 0 else '?'
def usym(x):
    i = bisect.bisect_right(UA, x) - 1
    return UN[i] if i >= 0 else '?'
KPAT = [('do_exit|do_group_exit|exit_mmap|mmput', 'kernel: exit teardown'),
        ('__x64_sys_madvise|do_madvise', 'kernel: madvise'),
        ('__x64_sys_munmap|__vm_munmap', 'kernel: munmap'),
        ('__x64_sys_mremap', 'kernel: mremap'),
        ('__x64_sys_mmap|ksys_mmap_pgoff|vm_mmap_pgoff', 'kernel: mmap'),
        ('exc_page_fault|handle_mm_fault|do_user_addr_fault', 'kernel: page fault'),
        ('futex', 'kernel: futex'),
        ('sysvec_call_function|flush_tlb_func|smp_call_function', 'kernel: TLB shootdown IPI'),
        ('__x64_sys_(read|pread64|openat|newfstatat|statx|getdents64|close|readlink|write)', 'kernel: file I/O'),
        ('execve|load_elf|begin_new_exec', 'kernel: exec'),
        ('sched_yield|schedule$|__schedule', 'kernel: scheduler'),
        ('clone|copy_process', 'kernel: thread start')]
def kind(frames, comm):
    if not frames: return '?'
    if frames[0] >= 0xffff000000000000:
        ks = [ksym(x) for x in frames if x >= 0xffff000000000000]
        # outermost-first matching: walk from the entry inward
        for pat, name in KPAT:
            for s in reversed(ks):
                if re.search(pat, s): return name
        return 'kernel: other (' + ks[-1] + '>' + ks[0] + ')' if len(ks) > 1 else 'kernel: other'
    s = usym(frames[0])
    if s.startswith('rig.sched') or 'sched.Fiber' in s: return 'user: rig.sched'
    if s.startswith('rig.alloc'): return 'user: rig.alloc'
    if comm == 'trig' and s == '?': return 'user: unresolved'
    return 'user: program'
c = Counter(); tot = 0; frames = []; comm = None
def flush():
    global tot
    if comm is not None and frames:
        c[kind(frames, comm)] += 1; tot += 1
for line in sys.stdin:
    if not line.strip():
        flush(); comm = None; frames = []; continue
    if not line.startswith((' ', '\t')):
        comm = line.split()[0]; continue
    m = re.match(r'\s+([0-9a-f]+)\s', line)
    if m: frames.append(int(m.group(1), 16))
flush()
for k, v in sorted(c.items(), key=lambda x: -x[1])[:25]:
    print(f"{100*v/tot:6.2f}%  {k}")
print(f"{tot} samples")
