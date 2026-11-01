#!/usr/bin/env python3
"""classify.py PKG OUT [--apply ARM DST]: find the yield-check sites (rig.turn)
of Trig's emitted Zig whose loops a "scan" rule would cover, and with
--apply write a copy of PKG to DST with those sites turned into rig.noTurn.

A loop is covered when
  1. its turn count is fixed by a length at entry: a Zig `for` (a walk
     over a slice, array, or List, whose length Zig reads once), a range
     loop whose end is `rig.lenOf(X)`, or a `while` whose condition
     compares against `rig.lenOf(X)` with X not assigned in the body; and
  2. its body does constant work per turn: every call is to a function
     that is loop-free (or whose loops are all covered), calls only such
     functions, is on no cycle, and reaches no scheduler, allocator or
     Zig std call; every loop nested in it is covered.

ARM is "std" (the covered sites in __rig_std_*.zig only) or "all".
This is a generous upper bound on what a sound rule could cover (it
does not ask that the index rise every turn), used to measure reach.
"""
import os, re, sys, shutil, json
from collections import Counter, defaultdict

pkg, out = sys.argv[1], sys.argv[2]
apply_arm = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == '--apply' else None

KEYWORDS = set('if while for switch return catch orelse and or try comptime inline struct union enum fn error defer errdefer break continue align callconv noinline linksection addrspace anyframe suspend resume nosuspend await test usingnamespace asm volatile else'.split())

def strip_noise(src):
    """Blank out strings, chars and comments, keeping offsets."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            j = src.find('\n', i); j = n if j < 0 else j
            for k in range(i, j): out[k] = ' '
            i = j
        elif c == '\\' and i + 1 < n and src[i+1] == '\\':
            j = src.find('\n', i); j = n if j < 0 else j
            for k in range(i, j): out[k] = ' '
            i = j
        elif c == '"' or c == "'":
            q = c; j = i + 1
            while j < n and src[j] != q:
                if src[j] == '\\': j += 1
                if src[j] == '\n': break
                j += 1
            for k in range(i + 1, min(j, n)): out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)

def match_close(s, i, o, c):
    d = 0
    for j in range(i, len(s)):
        if s[j] == o: d += 1
        elif s[j] == c:
            d -= 1
            if d == 0: return j
    return -1

files = {}
for root, _, names in os.walk(pkg):
    if '.zig-cache' in root: continue
    for nm in names:
        if nm.endswith('.zig'):
            p = os.path.join(root, nm)
            src = open(p).read()
            files[os.path.relpath(p, pkg)] = (src, strip_noise(src))

# ---- imports -----------------------------------------------------------
IMP = re.compile(r'const\s+(\w+)\s*=\s*@import\("([^"]+)"\)')
imports = {}
for f, (src, s_) in files.items():
    d = {}
    for m in IMP.finditer(src):
        tgt = os.path.normpath(os.path.join(os.path.dirname(f), m.group(2)))
        if tgt in files: d[m.group(1)] = tgt
    imports[f] = d

# ---- functions ---------------------------------------------------------
FN = re.compile(r'\b(?:(pub)\s+)?(?:(inline|noinline|export|extern)\s+)?fn\s+(@"[^"]*"|\w+)\s*\(')
fns = defaultdict(list)   # name -> [(file, body_start, body_end, returns_type)]
for f, (src, s) in files.items():
    for m in FN.finditer(s):
        if m.group(2) == 'extern': continue
        p0 = m.end() - 1
        p1 = match_close(s, p0, '(', ')')
        if p1 < 0: continue
        j = p1 + 1; depth = 0
        while j < len(s):
            ch = s[j]
            if ch in '([': depth += 1
            elif ch in ')]': depth -= 1
            elif ch == ';' and depth == 0: j = -1; break
            elif ch == '{' and depth == 0:
                before = s[p1+1:j].rstrip()
                if re.search(r'(error|struct|union|enum|opaque)(\([^)]*\))?$', before):
                    j = match_close(s, j, '{', '}') + 1; continue
                break
            j += 1
        if j < 0 or j >= len(s): continue
        e = match_close(s, j, '{', '}')
        ret = s[p1+1:j].strip()
        fns[m.group(3)].append((f, j, e, ret == 'type' or ret.endswith(' type'), m.group(2) == 'inline'))
byfile = defaultdict(list)
for name, defs in fns.items():
    for d in defs: byfile[(d[0], name)].append(d)

def resolve(f, parts):
    last = parts[-1]
    if len(parts) == 1:
        return byfile.get((f, last)) or fns.get(last)
    head = parts[0]
    if head in imports[f]:
        tgt = imports[f][head]
        if len(parts) == 2:
            r = byfile.get((tgt, last))
            if r: return r
            if tgt.startswith('rig/'):
                return [d for d in fns.get(last, []) if d[0].startswith('rig/')] or fns.get(last)
        return fns.get(last)
    return fns.get(last)

CALL = re.compile(r'(comptime\s+)?(@?[A-Za-z_][\w]*(?:\s*\.\s*\*?\s*[A-Za-z_]\w*)*)\s*\(')

def calls_in(s):
    for m in CALL.finditer(s):
        if m.group(1): continue
        name = m.group(2)
        if name.startswith('@'): continue
        parts = [p.strip() for p in name.replace('.*', '').split('.')]
        last = parts[-1]
        if last in KEYWORDS: continue
        yield name, parts, last

# ---- turn sites --------------------------------------------------------
TURN = re.compile(r'rig\.turn\(&(__rig_turns_\d+)\)')
sites = []  # dicts
for f, (src, s) in files.items():
    for m in TURN.finditer(s):
        ls = s.rfind('\n', 0, m.start()) + 1
        le = s.find('\n', m.start())
        line = s[ls:le]
        site = dict(file=f, pos=m.start(), end=m.end(), counter=m.group(1))
        stripped = line.strip()
        if stripped.startswith('rig.turn('):
            # first statement of a `for` body: the nearest open brace before it
            d = 0; k = m.start() - 1
            while k >= 0:
                if s[k] == '}': d += 1
                elif s[k] == '{':
                    if d == 0: break
                    d -= 1
                k -= 1
            hs = s.rfind('\n', 0, k) + 1
            header = s[hs:k]
            site['kind'] = 'for' if re.search(r'\bfor\s*\(', header) else 'other'
            site['body'] = (k, match_close(s, k, '{', '}'))
            site['header'] = header.strip()
        else:
            # continue expression of a `while`
            wm = re.search(r'\bwhile\s*\(', line)
            if not wm or not stripped.endswith('{'):
                site['kind'] = 'other'; site['body'] = (m.start(), m.end()); site['header'] = stripped
            else:
                k = le - 1
                while s[k] != '{': k -= 1
                site['body'] = (k, match_close(s, k, '{', '}'))
                site['header'] = stripped
                cp = ls + wm.end() - 1
                cond = s[cp + 1:match_close(s, cp, '(', ')')]
                if cond.strip() == 'true':
                    bm = re.match(r'\s*if\s*\(!\(', s[k + 1:])
                    if bm:
                        op = k + 1 + bm.end() - 2
                        cond = s[op:match_close(s, op, '(', ')') + 1]
                    else:
                        cond = ''
                    site['kind'] = 'while'
                else:
                    rm = re.match(r'(__rig_i_\d+)\s*<\s*(__rig_end_\d+)', cond.strip())
                    if rm:
                        dm = re.search(r'const\s+' + rm.group(2) + r'\s*:\s*\w+\s*=\s*([^;]*);', s[max(0, ls - 400):ls])
                        cond = dm.group(1) if dm else ''
                        site['kind'] = 'range'
                    else:
                        site['kind'] = 'while'
                site['cond'] = cond
        sites.append(site)

# ---- the classifier ----------------------------------------------------
fn_state = {}
std_seen = Counter()
# Zig std calls that do constant work and never block.
STD_OK = {'std.debug.assert', 'std.math.maxInt', 'std.math.minInt', 'std.mem.readInt', 'std.mem.writeInt', 'std.mem.nativeToLittle', 'std.mem.littleToNative', 'std.mem.nativeToBig', 'std.mem.bigToNative', 'std.math.cast', 'std.meta.Int', 'std.math.shl', 'std.math.shr', 'std.math.rotl', 'std.math.rotr', 'std.math.isNan', 'std.math.isInf', 'std.math.signbit', 'std.math.copysign', 'std.math.floor', 'std.math.ceil', 'std.math.absCast', 'std.math.order', 'std.math.add', 'std.math.sub', 'std.math.mul', 'std.math.isPowerOfTwo', 'std.enums.fromInt', 'std.debug.panic'}   # name -> True/False; 'busy' while in progress
block_reason = Counter()

self_pos = [None]
def site_ok_by_pos(f, a, b):
    """Every turn site inside [a, b) of file f is covered."""
    for st in sites_by_file[f]:
        if a <= st['pos'] < b and st['pos'] != self_pos[0] and not covered(st):
            return False
    return True

def body_ok(f, a, b, why):
    s = files[f][1]
    seg = s[a:b]
    if 'callKeeping' in seg or 'tickCall' in seg:
        why.append('scheduler'); return False
    if not site_ok_by_pos(f, a, b):
        why.append('nested loop not covered'); return False
    for name, parts, last in calls_in(seg):
        if name.startswith('rig.turn') or name.startswith('rig.noTurn'): continue
        if not fn_ok(f, parts):
            why.append(name); return False
    return True

def fn_ok(f0, parts):
    if parts[0] == 'builtin':
        return True   # target queries, known at compile time
    if parts[0] == 'std':
        std_seen['.'.join(parts)] += 1
        return '.'.join(parts) in STD_OK
    if len(parts) == 1 and re.search(r'const\s+' + re.escape(parts[0]) + r'\s*=\s*@"llvm\.', files[f0][0]):
        return True   # an LLVM intrinsic
    if parts[-1][:1].isupper():
        return True   # a type or type function
    defs = resolve(f0, parts)
    if not defs:
        return False
    method = len(parts) >= 2 and parts[0] not in imports[f0]
    any_ok = False
    for d in defs:
        if d[3]: continue
        key = (d[0], d[1])
        st = fn_state.get(key)
        if st == 'busy':
            if d[4]: continue   # inline recursion ends at compile time
            return False
        if st is None:
            fn_state[key] = 'busy'
            st = body_ok(d[0], d[1] + 1, d[2], [])
            fn_state[key] = st
        if st: any_ok = True
        elif not method: return False
    return any_ok or not method

memo = {}
def covered(st):
    key = (st['file'], st['pos'])
    if key in memo: return memo[key]
    memo[key] = False   # cycles: not covered
    why = []
    s = files[st['file']][1]
    ok = True
    if st['kind'] == 'for':
        pass
    elif st['kind'] == 'range':
        c = st['cond'].strip()
        if not (re.fullmatch(r'rig\.lenOf\([^()]*\)', c) or re.fullmatch(r'\d+', c)):
            ok = False; why.append('range end not a length')
    elif st['kind'] == 'while':
        c = st['cond']
        lm = re.search(r'<=?\s*rig\.lenOf\(([^()]*)\)', c)
        if not lm:
            ok = False; why.append('condition not a length')
        else:
            x = lm.group(1).strip()
            a, b = st['body']
            if re.search(re.escape(x) + r'\s*=[^=]', s[a:b]):
                ok = False; why.append('length place assigned')
    else:
        ok = False; why.append('form')
    if ok:
        a, b = st['body']
        saved = self_pos[0]; self_pos[0] = st['pos']
        ok = body_ok(st['file'], a + 1, b, why)
        self_pos[0] = saved
    st['why'] = why
    memo[key] = ok
    return ok

sites_by_file = defaultdict(list)
for st in sites: sites_by_file[st['file']].append(st)

res = Counter(); per_file = Counter(); per_file_all = Counter(); blockers = Counter()
covered_sites = []
for st in sites:
    c = covered(st)
    std = st['file'].startswith('__rig_std_') or st['file'].startswith('rig/')
    res[(st['kind'], c)] += 1
    per_file_all[st['file']] += 1
    if c:
        per_file[st['file']] += 1
        covered_sites.append(st)
    else:
        for w in st.get('why', [])[:1]: blockers[w] += 1

with open(out, 'w') as o:
    o.write(f'turn sites: {len(sites)}; covered: {len(covered_sites)}\n')
    for k, v in sorted(res.items(), key=str): o.write(f'  {k[0]:6} covered={k[1]}: {v}\n')
    o.write('covered per file (covered / sites):\n')
    for f in sorted(per_file_all, key=lambda f: -per_file[f]):
        if per_file[f]: o.write(f'  {f}: {per_file[f]} / {per_file_all[f]}\n')
    o.write('first reason a site is not covered (top 40):\n')
    for w, v in blockers.most_common(40): o.write(f'  {v:5} {w}\n')
    o.write('Zig std calls met (top 30):\n')
    for w, v in std_seen.most_common(30): o.write(f'  {v:5} {w}\n')
    o.write('covered sites:\n')
    for st in covered_sites:
        src = files[st['file']][0]
        ln = src.count('\n', 0, st['pos']) + 1
        o.write(f"  {st['file']}:{ln} {st['kind']} {st['header'][:110]}\n")

if apply_arm:
    dst = sys.argv[5]
    if os.path.exists(dst): shutil.rmtree(dst)
    shutil.copytree(pkg, dst, ignore=shutil.ignore_patterns('.zig-cache'))
    by_file = defaultdict(list)
    for st in covered_sites:
        if apply_arm == 'std' and not st['file'].startswith('__rig_std_'): continue
        by_file[st['file']].append(st)
    n = 0
    for f, lst in by_file.items():
        src = files[f][0]
        for st in sorted(lst, key=lambda x: -x['pos']):
            assert src[st['pos']:st['pos'] + 9] == 'rig.turn('
            src = src[:st['pos']] + 'rig.noTurn(' + src[st['pos'] + 9:]
            n += 1
        open(os.path.join(dst, f), 'w').write(src)
    rt = os.path.join(dst, 'rig', 'runtime.zig')
    r = open(rt).read()
    anchor = 'pub inline fn turn(n: *u32) void {'
    assert anchor in r
    r = r.replace(anchor, '/// STUDY (scan-yield): a covered loop\'s turn checks nothing.\npub inline fn noTurn(n: *u32) void {\n    _ = n;\n}\n\n' + anchor)
    open(rt, 'w').write(r)
    print(f'{apply_arm}: {n} sites rewritten into {dst}')

if os.environ.get('WHY'):
    def explain(f0, parts, depth=0, seen=set()):
        defs = resolve(f0, parts)
        print('  ' * depth + '.'.join(parts), 'defs:', [(d[0], files[d[0]][0].count('\n', 0, d[1]) + 1, d[3]) for d in (defs or [])][:6])
        if not defs or depth > 4: return
        for d in defs:
            if d[3] or (d[0], d[1]) in seen: continue
            seen.add((d[0], d[1]))
            why = []
            if not body_ok(d[0], d[1] + 1, d[2], why):
                print('  ' * depth + '  blocked by', why)
                if why and why[0] not in ('scheduler', 'nested loop not covered'):
                    nm = why[0]
                    explain(d[0], [p.strip() for p in nm.replace('.*', '').split('.')], depth + 1, seen)
                return
    for w in os.environ['WHY'].split(','):
        explain(os.environ.get('WHYF','lexer.zig'), w.split('.'))
    for st in sites:
        if st['file']==os.environ.get('WHYF') and files[st['file']][0].count('\n',0,st['pos'])+1 in [int(x) for x in os.environ.get('WHYL','0').split(',')]:
            print('site', st['kind'], st.get('cond'), st.get('why'))
