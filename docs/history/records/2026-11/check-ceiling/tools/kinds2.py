#!/usr/bin/env python3
# kinds2.py PROJECT COST_PCT: the full-run census by the kinds Rig asked for, from census/class-P.tsv
# (classify.py's categories per site) and census/sites-P.tsv (each branch's inline chain).
import sys, re, collections
P, cost = sys.argv[1], float(sys.argv[2])
# std Map/Set/Ordered: branches whose innermost frame is in the tables' code.
MAP = re.compile(r'@(ordered|unordered)\.zig|__rig_std_prelude|\.Map\(|\.Set\(|HashMap|HashSet|Ordered')
mapw = collections.Counter(); T = 0.0
for line in open('census/sites-%s.tsv' % P):
    f, s, ins, a, k, chain = line.rstrip('\n').split('\t')
    if k == 'brk': continue
    w = int(s) / int(ins); T += w
    if MAP.search(chain.split(' < ')[0]): mapw[k] += w
REL = re.compile(r'relat|assignable|comparable|identical|compare_|structured_type|is_type_related|is_simple_type_related|subtype|each_type_related|some_type_related|signatures_related|properties_related|index_signatures_related|members_related|recursive_type_related|type_arguments_related|variances|union_or_intersection_related')
FRONT = {'a', 'a+', 'b+', 'c2n', 'c2r', 'c2p', 'hash', 'e', 'ctr', 'data', 'std'}
COVER = re.compile(r'self\.(recs|locs|lists|texts)\.(at|slot|constSlot)\((n|l|t|[a-z_]+)\.id\)|store\.types|\.types\.(at|slot|constSlot)\(|symbol_data|flows\.(at|slot)|symbols\.(at|slot)|node_flow')
out = collections.Counter(); ex = collections.defaultdict(collections.Counter); dead = 0.0
for line in open('census/class-%s.tsv' % P):
    c, w, n, k, site, text, fns = line.rstrip('\n').split('\t'); w = float(w)
    helper = site.split('@')[0]
    if c in ('b-built', 'cold'): out['(not run) ' + c] += w; dead += w; continue
    if k == 'len' and 'check_id(' in text: b = 'H2 handle: Table length read in check_id (lenHeld misses Table)'
    elif c == 'd': b = 'H1 handle: index by an id' + (' (a Table store covers)' if COVER.search(text) else ' (other List)')
    elif c == 'd-rec': b = 'H3 handle: inside a record (offset/slice; Table alone does not cover)'
    elif c == 'zig': b = 'Z runtime and Zig std'
    elif c in FRONT: b = 'F front-end rule kinds: ' + c
    elif k in ('conv', 'ovf', 'shift') and REL.search(helper + ' ' + fns): b = 'R conversions/overflow in relation code'
    elif k in ('conv', 'ovf', 'shift'): b = 'C conversions/overflow elsewhere (' + ('checker' if helper.startswith(('checker.', 'declarations.')) else helper.split('.')[0]) + ')'
    elif k in ('index', 'slice') and helper.startswith(('checker.', 'declarations.', 'compiler.', 'evaluator.', 'binder.')): b = 'L List/slice index in ' + helper.split('.')[0]
    else: b = 'O other (' + helper.split('.')[0] + ' ' + k + ')'
    out[b] += w; ex[b][site + ' | ' + text[:110]] += w
live = 100.0 - dead
m = sum(mapw.values()) / T * 100
print('## %s (full c1; checks = %.1f%% of cycles)\n' % (P, cost))
print('std Map/Set/Ordered (innermost frame in the tables): %.2f%% of all weighted check branches (%s), ~%.2f%% of cycles; counted inside the rows below by their caller\n' % (m, ', '.join('%s %.2f' % (k, v / T * 100) for k, v in mapw.most_common()), m / live * cost))
print('| kind | share of all | share of live | ~% of cycles |\n|---|---:|---:|---:|')
for b, w in sorted(out.items(), key=lambda x: -x[1]):
    print('| %s | %.2f%% | %s | %s |' % (b, w, '' if b.startswith('(not') else '%.1f%%' % (w / live * 100), '~0' if b.startswith('(not') else '%.2f%%' % (w / live * cost)))
print()
for b, c in sorted(ex.items(), key=lambda x: -sum(x[1].values()))[:9]:
    print('- **%s**: ' % b + '; '.join('`%s` %.2f' % (s, w) for s, w in c.most_common(3)))
print()
