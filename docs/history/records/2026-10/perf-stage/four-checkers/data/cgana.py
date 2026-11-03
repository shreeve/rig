#!/usr/bin/env python3
"""cgana.py KIND OUT.json RUN.ck0.txt...: inclusive samples per checker
operation on checker 0's thread, from LBR call chains with inline frames
(RUN.ck0.txt), the leaf's source file (RUN.leaf) and each thread's first
sample (RUN.starts). KIND trig|tsrs. A sample counts once per operation
present in its chain. A hash-table sample has its leaf in hash-table code
(Trig: ordered.zig, unordered.zig; tsrs: hashbrown, packedmap.rs,
basedmap.rs, rustc-hash, indexmap, SSE2 intrinsics); its owner is the
relation cache when a relation-cache frame is near the leaf, else the
nearest operation in the chain."""
import sys, re, json, collections
kind, out, files = sys.argv[1], sys.argv[2], sys.argv[3:]
OPS = collections.OrderedDict([
    ('relations', ['is_related_to_ex', 'is_related_to', 'structured_type_related_to', 'structured_type_related_to_worker', 'recursive_type_related_to', 'is_type_related_to', 'check_type_related_to_ex', 'check_type_related_to']),
    ('relation cache', ['relation_get', 'relation_set']),
    ('instantiation', ['instantiate_type_with_alias', 'instantiate_type_with_alias_worker', 'instantiate_type_with_alias_slow', 'instantiate_type_worker', 'instantiate_type']),
    ('object/conditional/reference instantiation', ['get_object_type_instantiation', 'get_conditional_type_instantiation_of', 'get_conditional_type_instantiation_ex', 'get_conditional_type_instantiation', 'create_type_reference_ex', 'create_type_reference']),
    ('mapper_map', ['mapper_map', 'map']),
    ('get_type_of_symbol', ['get_type_of_symbol']),
    ('resolve_structured_type_members', ['resolve_structured_type_members', 'resolve_structured_type_members_worker']),
    ('infer_types', ['infer_types']),
    ('infer_from_types', ['infer_from_types']),
    ('get_signatures_of_type', ['get_signatures_of_type', 'get_signatures_of_structured_type']),
    ('resolved signatures', ['get_resolved_signature', 'resolve_call_expression', 'resolve_call', 'get_signature_from_declaration']),
    ('property lookup', ['get_property_of_type', 'get_property_of_type_ex', 'get_property_of_type_worker', 'get_property_of_object_type', 'get_property_of_union_or_intersection_type', 'get_union_or_intersection_property']),
    ('union construction', ['get_union_type_ex', 'get_union_type', 'get_union_type_worker', 'get_union_type_worker_inner', 'get_union_type_ex_uncached']),
    ('intersection construction', ['get_intersection_type_ex', 'get_intersection_type', 'get_intersection_type_worker']),
])
LOOKUP = {}
for op, names in OPS.items():
    for n in names:
        LOOKUP.setdefault(n, op)
LOOKUP.pop('map', None)  # tsrs's TypeMapper::map is an inline frame named 'map', as are iterator adapters: not attributable
MAPFILE = re.compile(r'ordered\.zig|unordered\.zig') if kind == 'trig' else re.compile(r'hashbrown|packedmap\.rs|basedmap\.rs|rustc.hash|indexmap|x86/sse2\.rs')
REL = set(OPS['relations']) | {'is_simple_type_related_to'}

def tail(frame):
    nm = frame.replace(' (inlined)', '').strip()
    nm = re.sub(r'<.*$', '', nm) if not nm.startswith('<') else nm
    return nm.rsplit('::', 1)[-1]

def op_of(frame):
    return LOOKUP.get(tail(frame))

def rel_cache(frames):
    for a, b in zip(frames, frames[1:]):
        ta, tb = tail(a), tail(b)
        if ta in ('relation_get', 'relation_set'): return True
        if kind == 'tsrs' and ta in ('lookup', 'set') and tb in REL: return True
    return False

incl = {'cycles': collections.Counter(), 'instr': collections.Counter()}
mapown = {'cycles': collections.Counter(), 'instr': collections.Counter()}
total = collections.Counter(); maptot = collections.Counter(); runs = 0
for f in files:
    runs += 1
    starts = {}
    try:
        for l in open(f.replace('.ck0.txt', '.starts')):
            t, s = l.split(); starts[int(t)] = float(s)
    except FileNotFoundError:
        pass
    leaf = {}
    try:
        for l in open(f.replace('.ck0.txt', '.leaf')):
            p = l.split()
            if len(p) == 2: leaf[p[0]] = p[1]
    except FileNotFoundError:
        pass
    samples = []; cur = None
    for l in open(f):
        if not l.strip():
            cur = None; continue
        if not l.startswith('\t') and not l.startswith(' '):
            p = l.split()
            ts = p[1].rstrip(':')
            cur = [int(p[0]), float(ts), 'instr' if 'instr' in p[2] else 'cycles', [], leaf.get(ts)]
            samples.append(cur)
        elif cur is not None:
            parts = l.strip().split(None, 1)
            if len(parts) == 2: cur[3].append(parts[1])
    if not samples: continue
    tid = samples[0][0]
    lo, hi = -1e18, 1e18
    if kind == 'trig':
        others = sorted(s for t, s in starts.items() if t != tid)
        if len(others) >= 3: lo = others[-1] - 0.002
        withop = [s[1] for s in samples if any(op_of(fr) for fr in s[3])]
        if withop: hi = max(withop)
    for _, ts, ev, frames, lf in samples:
        if ts < lo or ts > hi: continue
        total[ev] += 1
        ops = set(filter(None, (op_of(fr) for fr in frames)))
        if rel_cache(frames): ops.add('relation cache')
        for o in ops: incl[ev][o] += 1
        if lf and MAPFILE.search(lf):
            maptot[ev] += 1
            owner = 'relation cache' if rel_cache(frames[:8]) else next((op_of(fr) for fr in frames if op_of(fr)), 'none')
            mapown[ev][owner] += 1
json.dump({'runs': runs, 'total': total, 'incl': incl, 'maptot': maptot, 'mapown': mapown}, open(out, 'w'))
print(out, runs, dict(total), dict(maptot))
