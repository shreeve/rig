#!/usr/bin/env python3
"""split.py PKG OUT N: cut a Rig-emitted Zig package into N units.

Each unit is a full copy of the package in OUT/uK. A function of a Trig
module (any file not under rig/ and not named __rig_*) is owned by one
unit: there it keeps its body and exports a C-ABI thunk; in every other
unit its body becomes a call through that thunk (__rig_x.call). Inline,
generic, comptime-parameter and inferred-error functions stay in every
unit, as do the runtime (rig/), std's emitted modules and the root.

The runtime's module-level globals become one storage each, defined in
unit 0 and reached from the others by symbol (rigg_FILE_NAME), so every
unit shares the allocator, scheduler, output and panic state.

Every unit is a `zig build-obj`; OUT/entry.zig is the executable's root,
whose `main` calls unit 0's `rig_entry`. Each unit's root first names
every error the program can make (__rig_errseed.zig), so that each
compilation numbers errors alike; rig_entry checks that they did.
"""
import os, re, shutil, sys, glob, json

PKG, OUT, N = sys.argv[1], sys.argv[2], int(sys.argv[3])
ZIGLIB = os.environ.get("ZIGLIB", "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib/std")
STATS = {}
TLS = []

# ---- lexing a line into code and non-code ------------------------------

def spans(line):
    """[(is_code, text)] for one line of Zig."""
    out, i, n, start = [], 0, len(line), 0
    while i < n:
        c = line[i]
        if c == '/' and line.startswith('//', i):
            out.append((True, line[start:i])); out.append((False, line[i:])); return out
        if c == '\\' and line.startswith('\\\\', i):
            out.append((True, line[start:i])); out.append((False, line[i:])); return out
        if c == '"' or c == "'":
            out.append((True, line[start:i]))
            j = i + 1
            while j < n and line[j] != c:
                j += 2 if line[j] == '\\' else 1
            out.append((False, line[i:j + 1])); i = j + 1; start = i; continue
        i += 1
    out.append((True, line[start:]))
    return out

def sub_code(line, pat, repl):
    return ''.join(re.sub(pat, repl, t) if code else t for code, t in spans(line))

# ---- runtime globals ---------------------------------------------------

GLOBAL_RE = re.compile(r'^(pub )?(threadlocal )?var (\w+)(?:: (.+?))?(?: align\((\d+)\))? = (.*);$')
GLOBAL_FILES = ['rig/alloc.zig', 'rig/runtime.zig', 'rig/sched.zig', 'rig/tasks.zig']
CROSS = [  # uses of public globals from other files that need a dereference
    (r'\b(rt\.sched|sched)\.deterministic\b', r'\1.deterministic.*'),
    (r'\bsched\.seed_value\b', r'sched.seed_value.*'),
    (r'\b(rt|rig)\.process\b(?!\.\*)', r'\1.process.*'),
]

def transform_globals(text, fname):
    lines = text.split('\n')
    stem = os.path.splitext(os.path.basename(fname))[0]
    globals_, out = [], []
    for i, l in enumerate(lines):
        m = GLOBAL_RE.match(l)
        if not m:
            continue
        pub, tl, name, ty, al, init = m.groups()
        if ty is None:
            ty = 'bool' if init in ('false', 'true') else None
        assert ty, (fname, l)
        globals_.append(dict(line=i, pub=pub or '', tl=bool(tl), name=name, ty=ty, al=al, init=init))
    names = {g['name']: g for g in globals_}
    decl_lines = {g['line'] for g in globals_}
    shadow = []
    for i, l in enumerate(lines):
        if i in decl_lines:
            continue
        for name, g in names.items():
            if not re.search(r'\b' + name + r'\b', l):
                continue
            if re.search(r'\b(const|var|fn) ' + name + r'\b', ''.join(t for c, t in spans(l) if c)):
                shadow.append((fname, i + 1, l.strip()))
            rep = name + '__p().*' if g['tl'] else name + '.*'
            if re.search(r'\benum\s*[({]', l):
                continue
            l = sub_code(l, r'(?<![.\w@])(?<!fn )' + name + r'\b(?!\s*:[^=])(?!__)', rep)
        lines[i] = l
    for g in globals_:
        sym = f"rigg_{stem}_{g['name']}"
        ty, name = g['ty'], g['name']
        al = f"@max(@alignOf({ty}), {g['al']})" if g['al'] else f"@alignOf({ty})"
        if g['tl']:
            rel = '../' if '/' in fname else ''
            lines[g['line']] = (
                f"pub const __rigg_T_{name} = {ty};\n"
                f"{g['pub']}inline fn {name}__p() *{ty} {{ return if (__rig_unit.is_main) @ptrCast(&@import(\"{rel}__rig_tls.zig\").{sym}) else "
                f"@ptrCast(@extern(*align({al}) [@sizeOf({ty})]u8, .{{ .name = \"{sym}\", .is_thread_local = true }})); }}")
            TLS.append(f"pub export threadlocal var {sym}: [@sizeOf(@import(\"{fname}\").__rigg_T_{name})]u8 align(@alignOf(@import(\"{fname}\").__rigg_T_{name})) = @splat(0);")
        else:
            lines[g['line']] = (
                f"var __rigg_store_{name}: [@sizeOf({ty})]u8 align({al}) = @splat(0);\n"
                f"{g['pub']}const {name}: *{ty} = if (__rig_unit.is_main) @ptrCast(&__rigg_store_{name}) else "
                f"@ptrCast(@extern(*align({al}) [@sizeOf({ty})]u8, .{{ .name = \"{sym}\" }}));")
    exports = '\n'.join(f"        @export(&__rigg_store_{g['name']}, .{{ .name = \"rigg_{stem}_{g['name']}\" }});" for g in globals_ if not g['tl'])
    inits = '\n'.join(
        (f"    {g['name']}__p().* = {g['init']};" if g['tl'] else f"    {g['name']}.* = {g['init']};")
        for g in globals_ if g['init'] != 'undefined')
    lines.append(f"const __rig_unit = @import(\"{'../' if '/' in fname else ''}__rig_unit.zig\");")
    lines.append("comptime {\n    if (__rig_unit.is_main) {\n" + exports + "\n    }\n}")
    lines.append("pub fn __rigg_init() void {\n" + inits + "\n}")
    STATS.setdefault('globals', {})[fname] = len(globals_)
    STATS.setdefault('shadow', []).extend(shadow)
    return '\n'.join(lines)

# ---- error seed --------------------------------------------------------

ERR_RE = re.compile(r'\berror\.(@"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)')
SET_RE = re.compile(r'\berror\s*\{([^{}]*)\}', re.S)

def error_names(paths):
    names = set()
    for p in paths:
        try:
            src = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for m in ERR_RE.finditer(src):
            names.add(m.group(1))
        for m in SET_RE.finditer(src):
            body = re.sub(r'//[^\n]*', '', m.group(1))
            for part in body.split(','):
                part = part.strip()
                if re.fullmatch(r'@"[^"]*"|[A-Za-z_][A-Za-z0-9_]*', part):
                    names.add(part)
    names.discard('_')
    return sorted(names)

# ---- functions of Trig modules -----------------------------------------

FN_RE = re.compile(r'^(?P<ind> *)(?P<pub>pub )?(?P<kw>(?:inline |export |extern |noinline )*)fn (?P<name>@"[^"]+"|\w+)\((?P<params>.*)\) (?P<ret>.*) \{$')
CONT_RE = re.compile(r'^(?P<ind> *)(?:pub )?const (?P<name>@"[^"]+"|\w+) = (?:extern |packed )?(?:struct|union|enum|opaque)\b.*\{$')

def split_top(s):
    parts, depth, cur, i = [], 0, '', 0
    for code, t in spans(s):
        if not code:
            cur += t; continue
        for ch in t:
            if ch in '([{': depth += 1
            elif ch in ')]}': depth -= 1
            if ch == ',' and depth == 0:
                parts.append(cur); cur = ''
            else:
                cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts]

def eligible(m):
    why = None
    if m.group('kw').strip():
        why = 'inline/export'
    elif m.group('name') == 'main':
        why = 'main'
    ret = m.group('ret')
    if not why and (ret.startswith('!') or 'anytype' in ret or '@TypeOf' in ret or 'noreturn' in ret
                    or 'callconv' in ret or ret in ('type', 'comptime_int', 'comptime_float')):
        why = 'return'
    params = []
    if not why:
        for p in split_top(m.group('params')):
            pm = re.fullmatch(r'(noalias )?(@"[^"]+"|\w+): (.+)', p)
            if not pm or p.startswith('comptime ') or 'anytype' in p or pm.group(3) in ('type', 'comptime_int'):
                why = 'param'; break
            if pm.group(2) == '_':
                why = 'param'; break
            params.append(pm.group(2))
    return why, params

def scan(lines):
    """Functions at container level: (start, end, path, match, why, params)."""
    fns, stack, i = [], [], 0
    while i < len(lines):
        l = lines[i]
        while stack and l == stack[-1][0] + '};':
            stack.pop()
        m = FN_RE.match(l)
        if m:
            ind = m.group('ind')
            j = i + 1
            while lines[j] != ind + '}':
                j += 1
            why, params = eligible(m)
            fns.append(dict(start=i, end=j, path=[c for _, c in stack] + [m.group('name')], m=m,
                            why=why, params=params, weight=j - i))
            i = j + 1
            continue
        c = CONT_RE.match(l)
        if c:
            stack.append((c.group('ind'), c.group('name')))
        i += 1
    return fns

def sym_of(stem, path):
    return 'rigx_' + stem + '__' + '__'.join(p.replace('@"', '').replace('"', '').replace('.', '_') for p in path)

# ---- the call graph, and a cut that follows it -------------------------

CG = os.environ.get('SPLIT_CG') == '1'
# Seconds of one unit's compile per 1,000 lines a module's functions own,
# fitted to the 4- and 8-unit builds' units (README, "Balance"), as
# multiples of checker's.
COST = {'checker': 1.0, 'ast': 1.65, 'binder': 1.65, 'parser': 1.27, 'lexer': 1.27,
        'printer': 1.34, 'sourcemap': 1.34, 'transformers': 3.38, 'tsoptions': 1.33,
        'tspath': 1.33, 'vfs': 1.33, 'vfsmatch': 1.33, 'misc': 2.42}
CALL_RE = re.compile(r'(?:\b(\w+)\s*\.\s*)?\b([A-Za-z_]\w*)\s*\(')

def refine(texts, split_files, scans, allfns):
    """Move functions between units toward the units they call and are
    called from, keeping each unit's cost within 3% of the mean. Edges are
    call sites, found by name: `mod.f(` a module's function, `x.f(` a
    method of that name (of the caller's own container first), `f(` the
    caller's container's or file's. An inline function's calls count as
    its callers', to a depth of three."""
    alias = {}
    for f in split_files:
        for m in re.finditer(r'^const (\w+) = @import\("([\w.]+)\.zig"\);', texts[f], re.M):
            alias.setdefault(f, {})[m.group(1)] = m.group(2) + '.zig'
    nodes = []          # every function of the Trig modules, inline ones too
    by_top = {}         # (file, name) -> node, a file's top-level functions
    by_method = {}      # name -> [node], methods of any container
    by_cont = {}        # (file, container path, name) -> node
    for f in split_files:
        lines = texts[f].split('\n')
        for fn in scans[f]:
            node = dict(fn=fn, file=f, cont=tuple(fn['path'][:-1]), name=fn['path'][-1],
                        body='\n'.join(lines[fn['start'] + 1:fn['end']]), out={})
            nodes.append(node)
            by_cont[(f, node['cont'], node['name'])] = node
            if node['cont']:
                by_method.setdefault(node['name'], []).append(node)
            else:
                by_top[(f, node['name'])] = node
    for node in nodes:
        code = '\n'.join(''.join(t for c, t in spans(l) if c) for l in node['body'].split('\n'))
        for m in CALL_RE.finditer(code):
            q, name = m.groups()
            if q and q in alias.get(node['file'], {}):
                cands = [by_top.get((alias[node['file']][q], name))]
            elif q:
                own = by_cont.get((node['file'], node['cont'], name))
                cands = [own] if own else by_method.get(name, [])
            else:
                cands = [by_cont.get((node['file'], node['cont'], name)) or by_top.get((node['file'], name))]
            cands = [c for c in cands if c is not None and c is not node]
            if not cands or len(cands) > 4:
                continue
            for c in cands:
                node['out'][id(c)] = node['out'].get(id(c), 0) + 1.0 / len(cands)
    ident = {id(n): n for n in nodes}
    # An inline function's calls are its callers': fold them in.
    def folded(node, depth=0):
        out = {}
        for cid, w in node['out'].items():
            c = ident[cid]
            if c['fn']['why'] == 'inline/export' and depth < 3:
                for k, w2 in folded(c, depth + 1).items():
                    out[k] = out.get(k, 0) + w * w2
            elif c['fn']['why'] is None:
                out[cid] = out.get(cid, 0) + w
        return out
    split = [n for n in nodes if n['fn']['why'] is None]
    adj = {id(n): {} for n in split}
    for n in split:
        for cid, w in folded(n).items():
            if cid == id(n):
                continue
            adj[id(n)][cid] = adj[id(n)].get(cid, 0) + w
            adj[cid][id(n)] = adj[cid].get(id(n), 0) + w
    unit = {id(n): n['fn']['unit'] for n in split}
    weight = {id(n): n['fn']['weight'] for n in split}
    load = [0.0] * N
    for n in split:
        load[unit[id(n)]] += weight[id(n)]
    cap = 1.03 * sum(load) / N
    def cut():
        return sum(w for a, nb in adj.items() for b, w in nb.items() if unit[a] != unit[b]) / 2
    before = cut()
    for _ in range(12):
        moved = 0
        for n in split:
            a = id(n)
            conn = [0.0] * N
            for b, w in adj[a].items():
                conn[unit[b]] += w
            cur = unit[a]
            best = max(range(N), key=lambda u: (conn[u], u == cur))
            if best != cur and conn[best] > conn[cur] and load[best] + weight[a] <= cap:
                load[cur] -= weight[a]; load[best] += weight[a]; unit[a] = best; moved += 1
        if not moved:
            break
    for n in split:
        n['fn']['unit'] = unit[id(n)]
    STATS['call_edges'] = sum(len(v) for v in adj.values()) // 2
    STATS['cut_weight_before'] = round(before)
    STATS['cut_weight_after'] = round(cut())
    STATS['total_edge_weight'] = round(sum(w for nb in adj.values() for w in nb.values()) / 2)

# ---- the build ---------------------------------------------------------

def main():
    files = sorted(os.path.relpath(p, PKG) for p in glob.glob(os.path.join(PKG, '**', '*.zig'), recursive=True)
                   if '.zig-cache' not in p)
    split_files = [f for f in files if '/' not in f and not f.startswith('__rig_')]
    texts = {f: open(os.path.join(PKG, f)).read() for f in files}
    for f in GLOBAL_FILES:
        texts[f] = transform_globals(texts[f], f)
    for f in files:
        for pat, rep in CROSS:
            texts[f] = '\n'.join(sub_code(l, pat, rep) for l in texts[f].split('\n'))

    # Every function of the Trig modules, in file order, cut into N runs of
    # about equal lines.
    scans = {f: scan(texts[f].split('\n')) for f in split_files}
    allfns = [(f, fn) for f in split_files for fn in scans[f] if fn['why'] is None]
    if CG:
        # A line of each module costs what the 4- and 8-unit builds
        # measured (README, "Balance"); the rest of the module groups 1.
        for f, fn in allfns:
            fn['weight'] = fn['weight'] * COST.get(os.path.splitext(f)[0], COST['misc'])
    total = sum(fn['weight'] for _, fn in allfns)
    acc = 0
    for f, fn in allfns:
        fn['unit'] = int(min(N - 1, acc * N // max(total, 1)))
        acc += fn['weight']
    if CG:
        refine(texts, split_files, scans, allfns)
    whys = {}
    for f in split_files:
        for fn in scans[f]:
            whys[fn['why'] or 'split'] = whys.get(fn['why'] or 'split', 0) + 1
    STATS['functions'] = whys
    STATS['split_lines'] = total
    STATS['unit_lines'] = [sum(fn['weight'] for _, fn in allfns if fn['unit'] == k) for k in range(N)]

    seed = error_names([os.path.join(PKG, f) for f in files] + glob.glob(os.path.join(ZIGLIB, '**', '*.zig'), recursive=True))
    STATS['error_names'] = len(seed)
    seed_src = 'pub const All = error{\n' + ''.join(f'    {n},\n' for n in seed) + '};\n'
    sig_src = (
        'const All = @import("__rig_errseed.zig").All;\n'
        '/// A hash of the number each compilation gave each error of the seed.\n'
        'pub fn signature() u64 {\n'
        '    @setEvalBranchQuota(10_000_000);\n'
        '    var h: u64 = 1469598103934665603;\n'
        '    inline for (@typeInfo(All).error_set.error_names.?) |n| {\n'
        '        h = (h ^ @intFromError(@field(anyerror, n))) *% 1099511628211;\n'
        '    }\n'
        '    return h;\n'
        '}\n')
    x_src = open(os.path.join(os.path.dirname(__file__), 'x.zig')).read()
    main_consts = re.findall(r'^pub const (\w+) = ', texts['__rig_main.zig'], re.M)
    reexport = ''.join(f'pub const {c} = M.{c};\n' for c in main_consts)

    for k in range(N + 1):  # unit N is the executable's root
        d = os.path.join(OUT, f'u{k}') if k < N else os.path.join(OUT, 'entry')
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(os.path.join(d, 'rig', 'std'), exist_ok=True)
        for f in files:
            t = texts[f]
            if k < N and f in split_files:
                t = cut(t, f, scans[f], k)
            p = os.path.join(d, f)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, 'w').write(t)
        # Only unit 0 defines the thread-local storage; the others' copy is
        # empty, never referenced, but must exist for Zig to read the import.
        open(os.path.join(d, '__rig_tls.zig'), 'w').write('\n'.join(TLS) + '\n' if k == 0 else '')
        open(os.path.join(d, '__rig_unit.zig'), 'w').write(f'pub const id = {k};\npub const is_main = {"true" if k == 0 else "false"};\n')
        open(os.path.join(d, '__rig_errseed.zig'), 'w').write(seed_src)
        open(os.path.join(d, '__rig_errsig.zig'), 'w').write(sig_src)
        open(os.path.join(d, '__rig_x.zig'), 'w').write(x_src)
        root = ['comptime { _ = @import("__rig_errseed.zig").All; }',
                'const std = @import("std");',
                'const M = @import("__rig_main.zig");',
                reexport]
        if k < N:
            root.append('comptime {\n' + ''.join(f'    _ = @import("{f}");\n' for f in split_files) + '}')
            root.append(f'export fn rigx_errsig_{k}() callconv(.c) u64 {{ return @import("__rig_errsig.zig").signature(); }}')
        if k == 0:
            decls = ''.join(f'extern fn rigx_errsig_{j}() callconv(.c) u64;\n' for j in range(1, N))
            checks = ''.join(f'    if (rigx_errsig_{j}() != mine) @panic("unit {j} numbers errors differently");\n' for j in range(1, N))
            root.append(decls + 'export fn rig_entry(init: *const anyopaque) callconv(.c) u8 {\n'
                        '    const mine = @import("__rig_errsig.zig").signature();\n' + checks +
                        ''.join(f'    @import("{g}").__rigg_init();\n' for g in GLOBAL_FILES) +
                        '    return M.main(@as(*const std.process.Init.Minimal, @ptrCast(@alignCast(init))).*);\n}')
        if k == N:
            root = ['const std = @import("std");',
                    'const M = @import("__rig_main.zig");',
                    'pub const panic = M.panic;', 'pub const std_options = M.std_options;',
                    'extern fn rig_entry(init: *const anyopaque) callconv(.c) u8;',
                    'pub fn main(init: std.process.Init.Minimal) u8 { return rig_entry(&init); }']
        open(os.path.join(d, '__rig_unit_root.zig'), 'w').write('\n'.join(root) + '\n')
    json.dump(STATS, open(os.path.join(OUT, 'split-stats.json'), 'w'), indent=1)
    print(json.dumps({k: v for k, v in STATS.items() if k != 'shadow'}, indent=1))
    for s in STATS.get('shadow', []):
        print('shadow?', *s)

def cut(text, f, fns, k):
    lines = text.split('\n')
    stem = os.path.splitext(f)[0]
    owned = []
    for fn in reversed(fns):
        if fn['why'] is not None:
            continue
        sym = sym_of(stem, fn['path'])
        if fn['unit'] == k:
            owned.append(('.'.join(fn['path']), sym))
            continue
        ind = fn['m'].group('ind')
        args = ', '.join(fn['params'])
        body = f"{ind}    return __rig_x.call(@This().{fn['m'].group('name')}, \"{sym}\", .{{ {args} }});"
        lines[fn['start'] + 1:fn['end']] = [body]
    lines.append('const __rig_x = @import("__rig_x.zig");')
    if owned:
        lines.append('comptime {\n    @setEvalBranchQuota(100_000_000);\n' + ''.join(f'    __rig_x.exportThunk({p}, "{s}");\n' for p, s in reversed(owned)) + '}')
    return '\n'.join(lines)

main()
