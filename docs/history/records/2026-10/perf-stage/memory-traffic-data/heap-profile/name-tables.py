# name-tables.py TABLES: name pagemap.py's table rows (#2..#44, in the order Store.new and Checker.new make them),
# with each element's bytes (mapping size / n) and the slots its resident pages hold.
import sys
names = [  # (name, n) in creation order
 ('types', 27), ('intrinsics', 26), ('literals', 26), ('unique_es_symbols', 26), ('structured', 26), ('references', 26),
 ('interfaces', 26), ('tuples', 26), ('instantiation_expressions', 26), ('mapped_types', 26), ('reverse_mapped_types', 26),
 ('evolving_arrays', 26), ('union_or_intersections', 26), ('type_parameters', 26), ('index_types', 26), ('indexed_accesses', 26),
 ('template_literals', 26), ('string_mappings', 26), ('substitutions', 26), ('conditionals', 26), ('signatures', 25),
 ('composites', 19), ('type_predicates', 22), ('index_infos', 23), ('type_aliases', 21), ('conditional_roots', 20),
 ('mappers', 24), ('type_lists', 28), ('sym_lists', 28), ('sig_lists', 28), ('info_lists', 28), ('node_lists', 28),
 ('atom_lists', 28), ('element_info_lists', 28), ('variance_lists', 28), ('signature_links', 27), ('symbol_node_links', 27),
 ('type_node_links', 27), ('value_symbol_links', 27), ('late_bound_links', 27), ('declared_type_links', 27),
 ('members_links', 27), ('checker.syms (CheckerSymbol)', 26)]
rows = []
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) == 7 and f[0].isdigit() and int(f[0]) >= 2:
        i = int(f[0]); size = int(f[2]); res = float(f[3]); last = int(f[5])
        name, lg = names[i - 2]
        esz = size >> lg
        slots = (last + 1) * 4096 // esz if last >= 0 else 0
        rows.append((res, name, esz, slots, last + 1))
tot = sum(r[0] for r in rows)
print('%-30s %6s %10s %12s %8s  (span: slots up to the last resident page)' % ('table', 'B/slot', 'MiB', 'span slots', 'share'))
for res, name, esz, slots, pages in sorted(rows, reverse=True):
    if res >= 0.05:
        print('%-30s %6d %10.2f %12d %7.1f%%' % (name, esz, res, slots, 100 * res / tot))
print('%-30s %6s %10.2f' % ('all tables', '', tot))
