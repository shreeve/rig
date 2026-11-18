#!/usr/bin/env python3
"""Read a stall-trace dump (sched.ST) and the generator's log."""
import struct, sys, collections
KIND = {1:'sleepIn', 2:'sleepOut', 3:'pollWait', 4:'pollRet', 5:'lookBusy', 6:'ev', 7:'run', 8:'steal',
        9:'wakeWorker', 10:'kick', 11:'preempt', 12:'declined', 13:'monSignal', 14:'monTick', 15:'trim+', 16:'trim-',
        17:'accept', 18:'read', 19:'waitRead', 20:'wrote', 21:'behind', 22:'svcAll+', 23:'svcAll-', 24:'sleep+', 25:'sleep-'}
def load(path):
    b = open(path, 'rb').read()
    magic, tf, slots, per = struct.unpack_from('<4Q', b, 0)
    off = 32
    evs = []
    for _ in range(slots):
        i, n = struct.unpack_from('<2Q', b, off); off += 16
        for k in range(n):
            t, kind, pad, w, a = struct.unpack_from('<QBBHI', b, off + 16 * k)
            evs.append((t, i, k, kind, w, a))
        off += 16 * n
    ports = struct.unpack_from('<65536H', b, off)
    # The clock counts microseconds: ties keep each thread's own order.
    evs.sort()
    evs = [(t, i, kind, w, a) for (t, i, _, kind, w, a) in evs]
    return tf, evs, ports
def gen(path):
    S = []; other = []
    for l in open(path):
        f = l.split()
        if f[0] == 'S':
            S.append(dict(conn=int(f[1]), port=int(f[2]), intended=int(f[3]), sent=int(f[4]), first=int(f[5]), got=int(f[6]), prev=int(f[7])))
        elif f[0] in 'TGFRE':
            other.append(f)
    return S, other

def clusters(S, gap=50_000_000):
    """Stalled requests grouped by time: those whose waits overlap."""
    S = sorted(S, key=lambda r: r['intended'])
    out = []
    for r in S:
        if out and r['intended'] <= out[-1]['end'] + gap:
            c = out[-1]; c['reqs'].append(r); c['end'] = max(c['end'], r['got'])
        else:
            out.append(dict(start=r['intended'], end=r['got'], reqs=[r]))
    return out

def report(dump, S, t0=None, t1=None, workers=10):
    tf, evs, ports = load(dump)
    fd_of = {p: fd for fd, p in enumerate(ports) if p}
    cl = [c for c in clusters(S) if c['start'] < tf and c['end'] > tf - 3e9]
    print('dump', dump, 'freeze', tf, 'events', len(evs))
    for c in cl:
        worst = max(c['reqs'], key=lambda r: r['got'] - r['intended'])
        print('cluster: %d requests, from %+.3f ms to %+.3f ms of freeze; worst %.1f ms (conn %d port %d)' % (
            len(c['reqs']), (c['start'] - tf) / 1e6, (c['end'] - tf) / 1e6, (worst['got'] - worst['intended']) / 1e6, worst['conn'], worst['port']))
        lo, hi = c['start'] - 5_000_000, c['end'] + 2_000_000
        # Per request: generator's sent/first/got against the server's events on its fd.
        for r in sorted(c['reqs'], key=lambda r: r['sent'])[:12]:
            fd = fd_of.get(r['port'])
            mine = [(t, i, k, w, a) for (t, i, k, w, a) in evs if k in (6, 18, 19, 20) and a == fd and r['sent'] - 1_000_000 <= t <= r['got'] + 1_000_000]
            def rel(t): return '%+.3f' % ((t - r['sent']) / 1e6)
            print('  conn %3d fd %s: intended %s sent 0 first %s got %s | %s' % (r['conn'], fd, rel(r['intended']), rel(r['first']), rel(r['got']),
                  ' '.join('%s@w%d:%s' % (KIND[k], i, rel(t)) for (t, i, k, w, a) in mine)))
        yield (lo, hi, evs, tf)

def timeline(evs, lo, hi, step=1_000_000, slots=range(0, 11)):
    """Per thread, per step: what it did. r=runs s=asleep p=poll events m=monitor signal P=preempt"""
    nb = int((hi - lo) // step) + 1
    rows = {}
    state = {}
    for (t, i, k, w, a) in evs:
        if t < lo - 50_000_000: continue
        if t > hi: break
        if k == 24: state[i] = 's'
        if k == 25: state[i] = '.'
        if t < lo: continue
        b = int((t - lo) // step)
        row = rows.setdefault(i, [collections.Counter() for _ in range(nb)])
        row[b][k] += 1
    for i in sorted(rows):
        line = ''
        for c in rows[i]:
            if c[7]: ch = 'r' if c[7] < 10 else 'R'
            elif c[13]: ch = 'm'
            elif c[24] or c[3]: ch = 's'
            elif c[14]: ch = '.'
            elif sum(c.values()) == 0: ch = ' '
            else: ch = '+'
            line += ch
        print('%3d %s' % (i, line))

def offcpu(evs, lo, hi, tf, min_gap=4_000_000):
    """Gaps of over min_gap in a thread's events within [lo, hi]: those
    not spent waiting in a poller (off the CPU, or between two events of a
    running fiber), and waits in a poller that overran their timeout."""
    by = collections.defaultdict(list)
    for e in evs:
        if lo - 20_000_000 <= e[0] <= hi: by[e[1]].append(e)
    out = []
    for i, es in sorted(by.items()):
        for a, b in zip(es, es[1:]):
            gap = b[0] - a[0]
            if gap < min_gap or b[0] < lo: continue
            if a[2] == 3:  # a wait in a poller
                if a[4] == 0xffffffff: continue
                over = gap - a[4] * 1000
                if over >= min_gap: out.append((i, a[0], gap, 'poller wait of %d us woke %.1f ms late' % (a[4], over / 1e6)))
            elif i == 64 and a[2] == 14:
                over = gap - a[4] * 1000
                if over >= min_gap: out.append((i, a[0], gap, 'monitor period %d us, woke %.1f ms late' % (a[4], over / 1e6)))
            else:
                out.append((i, a[0], gap, 'no event between %s and %s' % (KIND[a[2]], KIND[b[2]])))
    for (i, t, gap, why) in sorted(out, key=lambda x: x[1]):
        print('    thread %2d at %+8.1f ms: %5.1f ms, %s' % (i, (t - tf) / 1e6, gap / 1e6, why))
    return out
