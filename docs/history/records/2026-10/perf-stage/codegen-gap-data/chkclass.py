#!/usr/bin/env python3
"""chkclass.py LINES: chk.py's per-line lists (every line), each bounds,
overflow and cast line put in a class by its emitted Zig: what a fact
the proofs pass can reach removes, what needs an index type, and what
neither does. Prints each class's share of retired instructions."""
import sys, re, collections
CLS = {
 'bounds': [
  ('span: a Table read at a list start plus k (needs Span)', r'\.atInt\(@as\(i64, @intCast\(@as\(u32, list\.start\)\)\) \+ k\)'),
  ('proof: a countdown or loop index over the same List', r'active_mappers\.at\(i\)|elemPtr\(xs, j - 1\)|elemPtrProven|atProven|constSlotProven|rig\.slice\(self\.bytes'),
  ('id: an index read from memory (needs an index type)', r'sym_loc\.at|recs\.at\(n\.id\)|recs\.at\(|bindings\.constSlot|\.symbols\.constSlot|syms\.atInt|node_base\.at|files\.constSlot|symbol_data\.constSlot|words\.at\(|sym_base\.at|caches\.(slot|constSlot)|lists\.at\(|\.at\(n\.id\)|\.constSlot\(f\)|declarations\.at\(k\)|\.at\(x\)|\.at\(s\)|\.at\(t\)|\.at\(id\)'),
 ],
 'overflow': [
  ('counter: an Int or length stepped by a small constant', r'(\+= [0-9]+;)|self\.len \+= 1|= k \+ 1;|1 \+ rig\.lenOf'),
  ('range: an id sum or difference Trig keeps in range', r'node_base\.at|sym_base\.at|binder_tabs\)|binder_syms|words\.at\(d \+ i\)|word\(d \+ i\)|\+ off\)'),
 ],
 'cast': [
  ('proof: a Table length, below its n', r'lenOf\(self\.(store\.\w+|syms)\)'),
 ],
}
tot = collections.Counter(); cls = collections.Counter(); kind = None
for l in open(sys.argv[1]):
    m = re.match(r'## (\S+(?: \S+)?): ([0-9.]+)%', l)
    if m: kind = m.group(1); tot[kind] = float(m.group(2)); continue
    m = re.match(r'\s*([0-9.]+)% (\S+)\s+(.*)', l)
    if not m or kind not in CLS: continue
    share, src = float(m.group(1)), m.group(3)
    for name, rx in CLS[kind]:
        if re.search(rx, src): cls[(kind, name)] += share; break
    else: cls[(kind, 'other')] += share
for k in CLS:
    print(f'{k}: {tot[k]:.2f}% of retired instructions')
    for (kk, name), v in sorted(cls.items(), key=lambda x: -x[1]):
        if kk == k: print(f'  {v:5.2f}%  {name}')
