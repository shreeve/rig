#!/usr/bin/env python3
# analyze.py RAW: the census tables of tsrs.md from RAW/census/*.arena, *.heap.sites, RAW/shipped/*.memsplit,
# RAW/smaps/*.smaps. Prints Markdown on stdout.
import sys, re, collections, os

RAW = sys.argv[1]
MIB = 1 << 20
PROJECTS = ['empty', 'zod3', 'ts-pattern']
MODES = ['shipped', 'go']

KINDS = [
    ('1', 'AST nodes'),
    ('2', 'identifiers and text'),
    ('3', 'symbols'),
    ('4', 'symbol tables and members'),
    ('5', 'types'),
    ('6', 'signatures'),
    ('7', 'links and side tables'),
    ('8', 'source and lib file text'),
    ('9', 'lists and maps'),
    ('10a', 'mappers'),
    ('10b', 'inference'),
    ('10c', 'flow nodes'),
    ('10d', 'diagnostics'),
    ('10e', 'node builder / printer'),
    ('10f', 'other checker objects'),
    ('10g', 'program, config, module resolution, other'),
]
KNAME = dict(KINDS)


def short(t):
    t = re.sub(r'\btsrs_[a-z_]+::', '', t)
    t = re.sub(r'\b(alloc|core|std)::([a-z_]+::)*', '', t)
    t = t.replace('rustc_hash::FxBuildHasher', 'Fx').replace('hashbrown::table::', '')
    return t


def arena_kind(name, slice_):
    n = short(name)
    s = f'[{n}]' if slice_ else n
    if slice_ and n in ('ptr::P<ast::Node>', 'ptr::P<lazylist::LazyNodeList>', 'ptr::P<ast::FileReference>', 'ptr::P<ast::SourceFile>'):
        return '1'
    if slice_ and n == 'ptr::P<symbol::Symbol>':
        return '4'
    if slice_ and n == 'ptr::P<types::Signature>':
        return '6'
    if slice_ and n == 'ptr::P<checker::InferenceInfo>':
        return '10b'
    if slice_ and n == 'ptr::P<diagnostic::Diagnostic>':
        return '10d'
    if slice_ and n.startswith('ptr::PSlot<'):
        return '7'
    if slice_ and (n.startswith('ptr::P<') or n in ('u32', 'u64')):
        return '9'
    if n in ('str', '&str') or 'PackedStr' in n or 'ArenaStringBuilder' in n or 'aligned4' in n:
        return '2'
    if re.search(r'^ast::(NodeAlloc|NodeAllocRare)<|^ast::(Node|NodeList|ModifierList|SourceFile|FileReference|Pragma|CommentDirective)$|^lazylist::', n):
        return '1'
    if n in ('symbol::Symbol', 'symbol::SymbolTables'):
        return '3'
    if n == 'symbol::SymbolTable':
        return '4'
    if n in ('types::Signature', 'types::SignatureRare', 'types::CompositeSignature'):
        return '6'
    if 'SymbolNodeLinks' in n or n in ('links::IdGroup', 'types::ValueSymbolLinksTail') or 'NodeBuilderLinks' in n or 'NodeBuilderSymbolLinks' in n:
        return '7'
    if n.startswith('mapper::'):
        return '10a'
    if 'Inference' in n or 'WideningContext' in n or n == 'RefCell<Vec<ptr::P<types::Type>>>':
        return '10b'
    if n.startswith('flow::') or n.startswith('flow_types::'):
        return '10c'
    if n.startswith('diagnostic::') or 'ErrorChain' in n:
        return '10d'
    if n.startswith('types::') or n == 'checker_09::LazyMemberTable':
        return '5'
    if n.startswith('RefCell<') or 'PackedMap' in n:
        return '9'
    if n.startswith(('nodebuilder_types::', 'printer_types::', 'emitcontext::', 'checker::PseudoChecker', 'type_::')):
        return '10e'
    if n.startswith(('relater', 'nameresolver::', 'checker::')):
        return '10f'
    return '10g'


def heap_kind(cont, site, callers):
    s = site + ' ' + callers
    if 'read_file' in site and 'tsrs_vfs' in site:
        return '8', 'source file text (`Vec<u8>`/`String` from `read_file`)'
    if 'tsrs_ast/src/symbol.rs' in site:
        if 'set_capacity' in site:
            return '4', 'symbol table entry buffers (`EntryVec`)'
        if 'boxed @ tsrs_ast/src/symbol.rs:554' in site:
            return '4', 'symbol table extras (`Box<SymbolMapExtra>`)'
        if cont == 'hash table':
            return '4', 'symbol table name indexes (hash tables)'
        return '4', 'symbol tables, other heap'
    if 'links.rs' in site or 'LinkStore' in site or 'linkstore' in site:
        return '7', 'link stores (hash tables / vectors)'
    if 'flowmemo' in site:
        return '10c', 'flow memo'
    if 'diagnostic' in site:
        return '10d', 'diagnostics (heap)'
    if re.search(r'tsrs_(parser|scanner)/', site):
        return '1', 'parser heap (pragmas, tables)'
    if 'tsrs_binder/' in site:
        return '3', 'binder heap'
    if 'tsrs_checker/' in site or 'tsrs_checker::' in site:
        return '9', None  # sub-row by site
    return '10g', None


def load_arena(path):
    rows = []
    for l in open(path):
        if l.startswith('#') or l.startswith('type\t'):
            continue
        f = l.rstrip('\n').split('\t')
        name, sl = f[0], f[1] == '1'
        sz, al, an, ab, ln, lb, lt, lp, lr, df, dr, dg = map(int, f[2:])
        rows.append(dict(name=name, slice=sl, size=sz, align=al, alloc_n=an, alloc_b=ab, live_n=ln, live_b=lb,
                         taken=lt, parse_b=lp, region_b=lr, dead_free=df, dead_rewind=dr, dead_region=dg))
    return rows


def load_heap(path):
    rows = []
    for l in open(path):
        if l.startswith('#') or l.startswith('usable_bytes'):
            continue
        u, b, n, cont, site, callers = l.rstrip('\n').split('\t')
        rows.append(dict(usable=int(u), req=int(b), n=int(n), cont=cont, site=site, callers=callers))
    return rows


def heap_header(path):
    l = open(path).readline()
    m = re.search(r'live blocks (\d+) requested (\d+) usable (\d+) \| allocations (\d+) bytes (\d+)', l)
    return tuple(map(int, m.groups()))


def arena_header(path):
    l = open(path).readline()
    m = re.search(r'live taken (\d+) \(thread arenas approx (\d+)\) \| memsplit arena used (\d+) \| free lists (\d+) blocks (\d+)', l)
    return tuple(map(int, m.groups()))


def mib(b):
    return f'{b / MIB:.2f}'


def fmt_n(n):
    return f'{n:,}'


def site_label(site):
    fn, _, loc = site.partition(' @ ')
    fn = short(fn)
    fn = re.sub(r'<Checker>::', '', fn)
    if len(fn) > 70:
        fn = fn[:67] + '...'
    return f'{fn} @ {loc}'


KTOT = {}


def table(proj, mode):
    A = load_arena(f'{RAW}/census/{proj}.{mode}.arena')
    H = load_heap(f'{RAW}/census/{proj}.{mode}.heap.sites')
    groups = collections.defaultdict(list)  # kind -> rows (label, rust, store, count, each, bytes)
    for r in A:
        if r['live_n'] == 0:
            continue
        k = arena_kind(r['name'], r['slice'])
        n = short(r['name'])
        raw = '::' not in n and n not in ('u32', 'u64', '&str')
        rust = f'`{n}`' if (raw or not r['slice']) else f'`[{n}]`'
        each = (f"{r['live_b'] / r['live_n']:.0f} avg" + ('' if raw else f" ({r['size']} per item)") if r['slice']
                else f"{r['size']} / {r['taken'] / r['live_n']:.0f}")
        store = 'arena' if r['region_b'] == 0 else ('arena (region)' if r['region_b'] == r['live_b'] else 'arena (+region)')
        groups[k].append((rust, store, r['live_n'], each, r['taken'], 'A'))
    heap_sub = collections.defaultdict(lambda: [0, 0])
    for r in H:
        k, label = heap_kind(r['cont'], r['site'], r['callers'])
        if label is None and re.search(r'(packedmap|basedmap)\.rs', r['site']):
            cs = [c for c in r['callers'].split(' < ') if 'packedmap' not in c and 'basedmap' not in c] or ['?']
            first = short(cs[0]).replace('<checker::Checker>::', '')
            label = f"{r['cont']}: {site_label(r['site']).split(' @ ')[0].split('<')[0]}<{short(r['site']).split('<', 1)[1].split('>>')[0]}>> from {first[:60]}"
        if label is None:
            label = f"{r['cont']}: {site_label(r['site'])}"
        e = heap_sub[(k, label)]
        e[0] += r['n']
        e[1] += r['usable']
    for (k, label), (n, b) in heap_sub.items():
        groups[k].append((label, 'heap', n, f'{b / n:.0f} avg', b, 'H'))
    out = []
    out.append('| kind | Rust type | store | count | bytes each | MiB |')
    out.append('|---|---|---|---:|---|---:|')
    grand = 0
    for k, kname in KINDS:
        rows = sorted(groups.get(k, []), key=lambda r: -r[4])
        if not rows:
            continue
        tot = sum(r[4] for r in rows)
        grand += tot
        cnt_a = sum(r[2] for r in rows if r[5] == 'A')
        ab = sum(r[4] for r in rows if r[5] == 'A')
        hb = sum(r[4] for r in rows if r[5] == 'H')
        stores = ' + '.join(x for x, b in (('arena', ab), ('heap', hb)) if b)
        out.append(f'| **{k} {kname}** | | {stores} | {fmt_n(cnt_a) if cnt_a else ""} | | **{mib(tot)}** |')
        lim = 10 if k in ('1', '5', '9', '7', '10g', '10f', '10e') else 6
        shown = [r for r in rows if r[4] >= 0.01 * MIB][:lim]
        for r in shown:
            out.append(f'| | {r[0]} | {r[1]} | {fmt_n(r[2])} | {r[3]} | {mib(r[4])} |')
        rest = rows[len(shown):]
        if rest:
            out.append(f'| | ({len(rest)} more) | | {fmt_n(sum(r[2] for r in rest))} | | {mib(sum(r[4] for r in rest))} |')
        if k == '1':
            ident = [r for r in rows if 'Identifier' in r[0]]
            if ident:
                pass
        if k == '2':
            ids = [r for r in groups.get('1', []) if 'identifier::Identifier' in r[0]]
            for r in ids:
                out.append(f'| | {r[0]} (counted in 1) | {r[1]} | {fmt_n(r[2])} | {r[3]} | ({mib(r[4])}) |')
    ah = arena_header(f'{RAW}/census/{proj}.{mode}.arena')
    hh = heap_header(f'{RAW}/census/{proj}.{mode}.heap')
    KTOT[(proj, mode)] = {k: sum(r[4] for r in groups.get(k, [])) for k, _ in KINDS}
    out.append(f'| **total** | arena live {mib(ah[0])} + heap live {mib(hh[2])} | | | | **{mib(grand)}** |')
    return '\n'.join(out), A, ah, hh


def memsplit(proj, mode):
    txt = open(f'{RAW}/shipped/{proj}.{mode}.memsplit').read()
    blk = txt.split('tsrs mem split: check end')[1].split('tsrs mem split:')[0]
    d = {}
    m = re.search(r'VmRSS ([\d.]+) MiB, VmHWM ([\d.]+) MiB, RssAnon ([\d.]+) MiB, RssFile ([\d.]+)', blk)
    d['rss'], d['hwm'], d['anon'], d['file'] = map(float, m.groups())
    m = re.search(r'split MiB: arena used ([\d.]+) \+ arena unused resident ([\d.]+) \+ arena other \(regions, untouched used\) ([-\d.]+) \| heap live ([\d.]+) \+ heap retained ([\d.]+) \(in pages ([\d.]+), outside pages ([\d.]+)\) \| stacks ([\d.]+) \| file ([\d.]+) \| = ([\d.]+)', blk)
    keys = ['arena_used', 'arena_unused', 'arena_other', 'heap_live', 'heap_retained', 'heap_in_pages', 'heap_outside', 'stacks', 'file_b', 'total']
    d.update(zip(keys, map(float, m.groups())))
    for name in ['arena reservation', 'thread stacks', 'heap and other anonymous', 'file-backed']:
        m = re.search(name + r': (\d+), ([\d.]+), ([\d.]+)', blk)
        d['huge_' + name] = float(m.group(3))
    # whole-run peak: VmHWM at exit
    ex = txt.split('tsrs mem split: exit')[1]
    d['hwm_exit'] = max(d['hwm'], float(re.search(r'VmHWM ([\d.]+) MiB', ex).group(1)))
    return d


def smaps(proj, mode):
    p = f'{RAW}/smaps/{proj}.{mode}.smaps'
    tot = int(re.search(r'total Rss (\d+)', open(p).readline()).group(1))
    text = rodata = data = libs = anon = 0
    for l in open(p):
        if l.startswith('#'):
            continue
        r, h, perms, path = l.rstrip('\n').split('\t')
        r = int(r)
        if path.endswith('/package/tsrs'):
            if 'x' in perms:
                text += r
            elif 'w' in perms:
                data += r
            else:
                rodata += r
        elif path.startswith('/'):
            libs += r
        else:
            anon += r
    return dict(total=tot, text=text, rodata=rodata, data=data, libs=libs, anon=anon)


def sizes():
    seen = {}
    for proj in PROJECTS:
        for mode in MODES:
            for r in load_arena(f'{RAW}/census/{proj}.{mode}.arena'):
                if r['slice']:
                    continue
                n = short(r['name'])
                e = seen.setdefault(n, [r['size'], r['align'], 0])
                e[2] = max(e[2], r['taken'])
    print('| Rust type | size_of | align_of | arena block (8-aligned) | live MiB, largest run |')
    print('|---|---:|---:|---:|---:|')
    for n, (sz, al, mx) in sorted(seen.items(), key=lambda kv: -kv[1][2]):
        if mx < 0.1 * MIB and n not in ('flow::FlowNode', 'flow::FlowList', 'checker::InferenceContext', 'checker::InferenceInfo', 'diagnostic::Diagnostic', 'ast::Node', 'mapper::RareTypeMapper', 'checker::InferenceContextRare'):
            continue
        print(f'| `{n}` | {sz} | {al} | {(sz + 7) // 8 * 8} | {mib(mx)} |')


def main():
    print('<!-- generated by tsrs-raw/analyze.py -->')
    if len(sys.argv) > 2 and sys.argv[2] == 'sizes':
        sizes()
        return
    summary = []
    for proj in PROJECTS:
        for mode in MODES:
            t, A, ah, hh = table(proj, mode)
            ms = memsplit(proj, mode)
            sm = smaps(proj, mode)
            print(f'\n### {proj}, {mode} mode\n')
            print(t)
            print()
            alloc_b = sum(r['alloc_b'] for r in A)
            alloc_n = sum(r['alloc_n'] for r in A)
            live_n = sum(r['live_n'] for r in A)
            dead_f = sum(r['dead_free'] for r in A)
            dead_r = sum(r['dead_rewind'] for r in A)
            dead_g = sum(r['dead_region'] for r in A)
            parse_b = sum(r['parse_b'] for r in A)
            print(f'Arena: {fmt_n(live_n)} live objects / {fmt_n(alloc_n)} allocated ({mib(alloc_b)} MiB allocated; '
                  f'given back: {mib(dead_f)} MiB to free lists, {mib(dead_r)} MiB by parser rewinds, {mib(dead_g)} MiB with freed regions). '
                  f'Live bytes allocated before `parse end`: {mib(parse_b)} MiB. '
                  f'Census live {fmt_n(ah[0])} B vs memsplit arena used {fmt_n(ah[2])} B '
                  f'(unattributed {fmt_n(ah[2] - ah[1])} B; free lists hold {fmt_n(ah[4])} B). '
                  f'Heap: {fmt_n(hh[0])} live blocks, {mib(hh[1])} MiB requested / {mib(hh[2])} MiB usable; '
                  f'{fmt_n(hh[3])} heap allocations ({mib(hh[4])} MiB) over the run.')
            summary.append((proj, mode, ms, sm, ah, hh))
    print('\n## Summary: live MiB at `check end` by kind (arena + heap)\n')
    cols = [(p, m) for p in PROJECTS for m in MODES]
    print('| kind | ' + ' | '.join(f'{p} {m}' for p, m in cols) + ' |')
    print('|---|' + '---:|' * len(cols))
    for k, kname in KINDS:
        print(f'| {k} {kname} | ' + ' | '.join(mib(KTOT[c][k]) for c in cols) + ' |')
    print('| **total** | ' + ' | '.join('**' + mib(sum(KTOT[c].values())) + '**' for c in cols) + ' |')
    print('\n## Peak RSS and its split (shipped binary, uninstrumented, `TSRS_MEM_SPLIT=1` at `check end`)\n')
    print('| project | mode | VmHWM | arena used | arena unused resident | arena other (regions, untouched) | heap live | heap retained (in pages / outside) | stacks | file-backed | of which tsrs text / rodata / data / shared libs | AnonHugePages (arena / heap) |')
    print('|---|---|---:|---:|---:|---:|---:|---|---:|---:|---|---|')
    for proj, mode, ms, sm, ah, hh in summary:
        print(f"| {proj} | {mode} | {ms['hwm_exit']:.1f} | {ms['arena_used']:.1f} | {ms['arena_unused']:.1f} | {ms['arena_other']:.1f} | "
              f"{ms['heap_live']:.1f} | {ms['heap_retained']:.1f} ({ms['heap_in_pages']:.1f} / {ms['heap_outside']:.1f}) | {ms['stacks']:.1f} | "
              f"{ms['file_b']:.1f} | {sm['text'] / 1024:.1f} / {sm['rodata'] / 1024:.1f} / {sm['data'] / 1024:.1f} / {sm['libs'] / 1024:.1f} | "
              f"{ms['huge_arena reservation']:.1f} / {ms['huge_heap and other anonymous']:.1f} |")


main()
