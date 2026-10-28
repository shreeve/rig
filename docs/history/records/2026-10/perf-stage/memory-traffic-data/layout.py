#!/usr/bin/env python3
# layout.py BIN NAME... : each named struct's size and its fields' offsets
# and sizes as the binary's DWARF says (llvm-dwarfdump), with the padding
# between them: how Rig laid out Trig's objects in Zig.
import sys, subprocess, re
b, want = sys.argv[1], sys.argv[2:]
out = subprocess.run(['/usr/bin/llvm-dwarfdump-22', '--debug-info', b], capture_output=True, text=True).stdout
dies = re.split(r'\n(?=0x[0-9a-f]+: )', out)
byoff = {}
for d in dies:
    m = re.match(r'(0x[0-9a-f]+): +(DW_TAG_\w+)', d)
    if m: byoff[int(m.group(1), 16)] = d
def attr(d, a):
    m = re.search(a + r'\s*\(([^)]*)\)', d); return m.group(1) if m else None
def size_of(off, depth=0):
    d = byoff.get(off)
    if not d or depth > 8: return None
    s = attr(d, 'DW_AT_byte_size')
    if s: return int(s, 0)
    t = attr(d, 'DW_AT_type')
    return size_of(int(t.split()[0], 16), depth + 1) if t else None
offs = sorted(byoff)
seen = set()
for i, o in enumerate(offs):
    d = byoff[o]
    if 'DW_TAG_structure_type' not in d.split('\n')[0]: continue
    name = (attr(d, 'DW_AT_name') or '').strip('"')
    short = re.sub(r'__rig_m\d+_', '', name)
    if not any(short == w or short.endswith('.' + w) for w in want) or short in seen: continue
    seen.add(short)
    sz = attr(d, 'DW_AT_byte_size')
    print('\n%s: %s bytes' % (short, int(sz, 0) if sz else '?'))
    fields = []
    for o2 in offs[i + 1:]:
        d2 = byoff[o2]
        if 'DW_TAG_member' not in d2.split('\n')[0]: break
        fn = (attr(d2, 'DW_AT_name') or '').strip('"')
        loc = attr(d2, 'DW_AT_data_member_location')
        t = attr(d2, 'DW_AT_type')
        tn = t.split('"')[1] if t and '"' in t else '?'
        fs = size_of(int(t.split()[0], 16)) if t else None
        fields.append((int(loc, 0) if loc else 0, fn, fs, re.sub(r'__rig_m\d+_', '', tn)))
    end = 0
    for off, fn, fs, tn in sorted(fields):
        pad = off - end
        print('  %4d %-36s %4s  %s%s' % (off, fn, fs, tn[:60], ('   <- %d bytes padding before' % pad) if pad > 0 else ''))
        end = off + (fs or 0)
    if sz and int(sz, 0) > end: print('  tail padding %d' % (int(sz, 0) - end))
