#!/usr/bin/env python3
# classify.py SITES-TEXT.tsv OUT.tsv: each check site (from sitetext.py) split among the census's
# categories (CENSUS.md, "Categories"), by the helper that holds it, its kind, and its Zig line.
import sys, re, collections

def ops_index(line):
    # The index operations on a line still tested (not *Proven .both, not *If): their argument text.
    out = []
    for m in re.finditer(r'(\.(at|slot|constSlot)\(|rig\.(at|elemPtr)\(|\.(at|slot|constSlot)Proven\(|rig\.atProven\(|rig\.indexBelow\()', line):
        if 'Proven(' in m.group(0):
            tail = line[m.end():m.end() + 120]
            if '.both)' in tail.split(';')[0][:80]: continue
        out.append(line[m.start():m.start() + 140])
    return out

def index_cat(op, helper):
    if re.match(r'(checker|binder|declarations|compiler)\.', helper) and re.match(r'\.(at|slot|constSlot)\((\w+|__rig_ix_\w+|self\.[\w.]+\.at\(.*|@as\(i64, @intCast\(@as\(u32, [\w.]+\)\)\))\)', op):
        return 'd'
    if 'indexBelow(' in op and '@backingInt' in op: return 'e'
    if re.search(r'\(self\.words\.at\(', op): return 'd'           # lists[words[i]]: an id stored in a word
    if re.search(r'\(\w+\.id\)|\(@as\(u32, \w+\.id\)\)|_ix_\d+_\d+\)', op) and '.data' not in op:
        return 'd'
    if re.search(r'\.at\(@as\(i64, @intCast\(@as\(u32, (\w+|self\.\w+|[\w.]+\.id)\)\)\)', op): return 'd'
    if '.data)))' in op or '.data))) +' in op: return 'd-rec'
    if re.search(r'^\.at\(d \+ i\)|^\.at\(k\)', op) and re.search(r'deep_clone|for_each_child|visit_list_mut|parent_list', helper): return 'd-rec'
    if re.search(r'rig\.at\(self\.(body|text), self\.pos\)', op): return 'c2n'
    if re.search(r'self\.(pos|token_start|value_start|value_end|full_start_pos)', op): return 'c2r'
    return None

HELPER = [
    # (helper regex, kind, category or [(cat, frac)])
    (r'ast\.Ast\.finish_node$', 'conv', 'a+'), (r'ast\.Ast\.finish_node$', 'index', 'd'),
    (r'ast\.Ast\.set_loc$', 'conv', 'a+'), (r'ast\.Ast\.set_list_loc$', 'conv', 'a+'),
    (r'ast\.Ast\.new_node$', 'conv', 'a'),
    (r'ast\.Ast\.add_list$', 'conv', None),  # by line below
    (r'ast\.Ast\.add_text$', 'conv', None),
    (r'ast\.Ast\.add_text$', 'zbounds', 'zig'),
    (r'ast\.Ast\.parent_child$', 'index', None),
    (r'ast\.Ast\.parent_list$', 'index', None),
    (r'ast\.Ast\.word$', 'index', 'b+'),
    (r'binder\.Binder\.bind_children_of$', 'ovf', 'b+'), (r'binder\.Binder\.bind_children_of$', 'index', 'b+'),
    (r'binder\.Binder\.bind_(list_)?word$', '*', 'b+'),
    (r'ast\.Ast\.set_parent_of_children$', '*', 'b+'),
    (r'ast\.Ast\.word_(node|list|bool)$|ast\.Ast\.set_member_word$', 'index', [('d', .5), ('d-rec', .5)]),
    (r'ast\.Ast\.word_(node|list|bool)$|ast\.Ast\.set_member_word$', 'ovf', 'd-rec'),
    (r'ast\.Ast\.list_node$', 'index', 'd-rec'),
    (r'ast\.Ast\.(nodes|text_of)$', 'slice', 'd-rec'),
    (r'ast\.Names\.text$', 'slice', 'd-rec'), (r'ast\.Names\.text$', 'index', 'd'),
    (r'lexer\.Scanner\.char$', 'index', 'c2n'),
    (r'lexer\.Scanner\.char_at$', '*', 'c2p'),
    (r'lexer\.Scanner\.scan$', 'slice', 'c2r'),
    (r'lexer\.Scanner\.skip_ascii_trivia$', '*', 'other'),   # text[p], p from class_end: needs a result fact
    (r'lexer\.Scanner\.(token_value|token_text|value_add|value_add_range)$', 'slice', 'c2r'),
    (r'lexer\.Scanner\.value_add$', 'zbounds', 'zig'),
    (r'__rig_std_text\.(class_end|find_any)$', 'index', 'cold'),
    (r'__rig_std_(text|utf8|sort|json|prelude|unicode)\.|^slices\.|^__rig_std_', '*', 'std'),
    (r'^(hash|mem|rig\.alloc|rig\.runtime|rig\.std|rig\.ordered|rig\.unordered|Io|debug|heap|sort|fmt|rig\.table)\.|^hash\.', '*', 'zig'),
    (r'ast\.Reader\.', '*', 'data'),
    (r'ast\.Ast\.place_name$|ast\.NameTable\.|ast\.Binding\.table_(put|get)$|ast\.Names\.(find_in|find_hashed|rebuild)$', '*', 'hash'),
    (r'parser\.make_identifier$', 'ovf', 'ctr'),
    (r'binder\.Binder\.new_symbol$', 'ovf', 'ctr'),
    (r'parser\.Parser\.token_piece$', '*', 'a+'),
    (r'binder\.Binder\.(new_symbol|new_flow_node|new_flow_list)$|ast\.Binding\.(new_table|extra_of)$|ast\.Ast\.add_text_list(_pieces|_strings)?$', 'conv', 'a'),
    (r'ast\.Ast\.(deep_clone|for_each_child|for_each_child_mut|visit_list_mut)$', 'ovf', 'd-rec'),
    (r'ast\.Ast\.add_name$', 'ovf', 'a'),
]
LINE = {
    # (helper, kind, line) -> split
    ('ast.Ast.add_list', 'conv', '815'): [('a+', 3 / 4.), ('a', 1 / 4.)],   # I32(pos), I32(end), U32(nodes.len) param; U32(@list_nodes.len)
    ('ast.Ast.add_list', 'conv', '823'): [('a', 1.)],
    ('ast.Ast.add_list', 'conv', '0'): [('a+', .5), ('a', .5)],
    ('ast.Ast.add_text', 'conv', '589'): [('a', .5), ('a+', .5)],          # U32(@text_bytes.len); U32(text.len) param
    ('ast.Ast.add_text', 'conv', '591'): [('a', 1.)],
    ('ast.Ast.add_text', 'conv', '0'): [('a', .75), ('a+', .25)],
    ('ast.Ast.parent_child', 'index', '1188'): [('b+', 1.)],                # words[i], i = d + k from the caller
    ('ast.Ast.parent_child', 'index', '1190'): [('d', 1.)],                 # recs[w], w a node id read from a word
    ('ast.Ast.parent_list', 'index', '1198'): [('b+', .5), ('d', .5)],      # lists[words[i]]
    ('ast.Ast.parent_list', 'index', '1205'): [('d-rec', .5), ('d', .5)],   # recs[list_nodes[k].id], k in the list's range
    ('ast.Ast.parent_list', 'index', '0'): [('b+', .25), ('d', .5), ('d-rec', .25)],
}

def classify(helper, kind, line_no, text):
    key = (helper, kind, line_no)
    if key in LINE: return LINE[key]
    for h, k, c in HELPER:
        if re.search(h, helper) and (k == '*' or k == kind) and c is not None:
            return [(c, 1.)] if isinstance(c, str) else c
    if line_no == '0': return [('unk', 1.)]
    if kind in ('zbounds', 'zslice', 'bytes', 'shift', 'len'): return [('zig' if kind != 'bytes' else 'data', 1.)]
    if kind == 'index':
        ops = ops_index(text)
        if not ops:
            if re.search(r'(atIf|slotIf|constSlotIf|okBelow)', text): return [('b-built', 1.)]
            return [('other', 1.)]
        cats = [index_cat(o, helper) or ('b-built' if 'If(' in o else 'other') for o in ops]
        live = [c for c in cats if c != 'b-built'] or cats
        n = len(live)
        return [(c, 1. / n) for c in live]
    if kind == 'conv':
        if re.search(r'self\.scanner\.|self\.(pos|token_start)', text): return [('a+', 1.)]
        if re.search(r'lenOf\(self\.|self\.[\w.]+\.length\(\)|lenOf\(self\.binding', text): return [('a', 1.)]
        if re.search(r'lenOf\(', text): return [('a+', 1.)]
        if re.search(r'@intCast\(@as\(i64, __rig_local_(pos|end)', text): return [('a+', 1.)]
        return [('other', 1.)]
    if kind == 'ovf':
        if re.search(r'self\.(pos|token_start)', text): return [('c2r', 1.)]
        if re.search(r'(count\.\*|_count|\.len|self\.k|self\.at) \+= 1', text): return [('ctr', 1.)]
        if '.data))) + ' in text: return [('d-rec', 1.)]
        return [('other', 1.)]
    if kind == 'slice':
        if re.search(r'self\.(pos|token_start|value_start|value_end)', text): return [('c2r', 1.)]
        if re.search(r'@as\(u32, r\.start\)', text): return [('d-rec', 1.)]
        return [('other', 1.)]
    return [('other', 1.)]

rows = []
for line in open(sys.argv[1]):
    w, n, kind, site, text, fns = line.rstrip('\n').split('\t')
    helper, _, loc = site.partition('@')
    line_no = loc.rsplit(':', 1)[-1] if ':' in loc else '0'
    for c, f in classify(helper, kind, line_no, text):
        rows.append((c, float(w) * f, int(n) * f, kind, site, text, fns))
with open(sys.argv[2], 'w') as o:
    for r in rows: o.write('%s\t%.4f\t%.1f\t%s\t%s\t%s\t%s\n' % r)
by = collections.Counter(); byk = collections.defaultdict(collections.Counter); nb = collections.Counter()
for c, w, n, k, *_ in rows: by[c] += w; byk[c][k] += w; nb[c] += n
for c, w in by.most_common():
    print('%-8s %6.2f%%  branches %6.0f   %s' % (c, w, nb[c], ', '.join('%s %.2f' % x for x in byk[c].most_common())))
