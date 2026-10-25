#!/usr/bin/env python3
# family.py SITES.tsv STORE_FUNS.txt: the check samples by family and by kind, and the top sites.
import sys, collections
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
total = int(rows[0][1]); rows = rows[1:]
store = set(open(sys.argv[2]).read().split())
symbol = set('node_id atom text checker_symbol data_ref data_place data_index new_symbol new_symbol_ex symbol_flags '
             'symbol_check_flags symbol_name symbol_parent symbol_export_symbol symbol_members symbol_exports '
             'symbol_value_declaration symbol_declaration_count symbol_declaration get_members get_exports '
             'checker_table new_table table_get sym_at'.split())
def family(fn):
    if fn.startswith('ast.'): return 'AST records (ast.Ast)'
    if fn.startswith('__rig_std___rig_builtin.'): return 'Map/Set/Table probing (std builtin)'
    if fn.startswith('__rig_std_text.'): return 'text.Interner'
    if fn.startswith('rig.alloc') : return 'allocator'
    if fn.startswith('checker.Ids.') or fn.startswith('checker.node_ref'): return 'symbol and id accessors'
    if fn.startswith('checker.Checker.'):
        name = fn.split('.')[2].split('__')[0]
        if name in symbol: return 'symbol and id accessors'
        if name in store: return 'store accessors'
        return 'checker, other'
    if fn.startswith('checker.Store.'): return 'store accessors'
    if fn.startswith(('parser.', 'binder.', 'lexer.')): return 'parser/binder/lexer'
    return 'other'
fam = collections.Counter(); kind = collections.Counter(); fk = collections.defaultdict(collections.Counter)
on = 0
for r in rows:
    n = int(r[1]); on += n
    f = family(r[3]); fam[f] += n; kind[r[2]] += n; fk[f][r[2]] += n
print(f'samples {total}; on check branches and their compare {on} ({100.0*on/total:.2f}%)\n')
print('by kind (share of all samples):')
for k, n in kind.most_common(): print(f'  {k:10} {n:6d}  {100.0*n/total:5.2f}%')
print('\nby family (share of check samples; of all samples):')
for f, n in fam.most_common():
    ks = ', '.join(f'{k} {v}' for k, v in fk[f].most_common())
    print(f'  {f:38} {n:6d}  {100.0*n/on:5.1f}%  {100.0*n/total:5.2f}%   ({ks})')
print('\ntop 40 sites:')
for r in rows[:40]:
    print(f'  {int(r[1]):5d} {100.0*int(r[1])/total:5.2f}%  {r[2]:8} {r[3][:60]:60} {r[4].split("/")[-1]}')
