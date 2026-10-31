#!/usr/bin/env python3
"""ceil.py SRC DST MODE: copy Rig's emitted Trig package SRC to DST and remove
the checks items 2 and 3 would remove. MODE:
  ceil   item 2's bounds (countdown, a decrement loop's index, a while
         loop's exit edge) and item 3's lengths (`1 + s.len`, Map/Set len)
  len    item 3's lengths alone
  ceilc  ceil, plus every `+= 1` (counters: the owner's call, measured only)
"""
import sys, os, re, shutil
src, dst, mode = sys.argv[1:4]
if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.zig-cache'))
hits = {}
def sub(fname_rx, rx, rep, tag, literal=True):
    n = 0
    for root, _, files in os.walk(dst):
        for f in files:
            if not f.endswith('.zig') or not re.search(fname_rx, f): continue
            p = os.path.join(root, f); s = open(p).read()
            if literal:
                k = s.count(rx); s2 = s.replace(rx, rep)
            else:
                s2, k = re.subn(rx, rep, s)
            if k: open(p, 'w').write(s2); n += k
    hits[tag] = hits.get(tag, 0) + n
# item 2: a countdown from a length, nothing in the loop writing the List
if mode != 'len': sub(r'checker', 'self.active_mappers.at(i)', 'self.active_mappers.atProven(i, .both)', 'B1 countdown find_active_mapper')
# item 2: std.sort's insertion: j counts down from i < xs.len, guarded by j > 0
if mode != 'len': sub(r'sort', 'rig.elemPtrProven(xs, j, .lower)', 'rig.elemPtrProven(xs, j, .both)', 'B2 sort xs[j]')
if mode != 'len': sub(r'sort', 'rig.elemPtr(xs, j - 1)', 'rig.elemPtrProven(xs, j - 1, .both)', 'B2 sort xs[j - 1]')
if mode != 'len': sub(r'sort', r'rig\.swap\(xs, j, j - 1\)', 'rig.swapProven(xs, j, j - 1, .both)', 'B2 sort swap', literal=False)
# item 2: `while s.len <= p: push`, then s[p] (the loop's exit edge)
if mode != 'len': sub(r'checker', 'self.conditional_flow_steps.constSlotProven(p, .lower)', 'self.conditional_flow_steps.constSlotProven(p, .both)', 'B3 while-exit conditional_flow_steps')
# item 3, lengths: a literal plus a length
sub(r'', r'(\b\d+) \+ (rig\.lenOf\()', r'\1 +% \2', 'L1 c + s.len', literal=False)
sub(r'', r'(rig\.lenOf\([\w.*]+\)) \+ (\d+\b)', r'\1 +% \2', 'L1 s.len + c', literal=False)
# item 3, lengths: a Map's or Set's len, which counts its table's entries
sub(r'prelude', 'self.len += 1;', 'self.len +%= 1;', 'L2 Map/Set len += 1')
if mode == 'ceilc':
    sub(r'', r'(\S) \+= 1;', r'\1 +%= 1;', 'C counters += 1', literal=False)
for k, v in hits.items(): print(f'{v:6d}  {k}')
