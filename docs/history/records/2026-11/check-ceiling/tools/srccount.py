#!/usr/bin/env python3
# srccount.py ZIG...: the checks left in emitted Zig, by kind (a static count of call sites).
import sys, re
pats = [
 ('List index, unproven (.at/.slot/.constSlot)', r'(?<!rig)\.(at|slot|constSlot)\('),
 ('List index, one test left (*Proven .lower/.upper)', r'\.(at|slot|constSlot)Proven\([^;]*?\.(lower|upper)\)'),
 ('List index, proven (*Proven .both)', r'\.(at|slot|constSlot)Proven\([^;]*?\.both\)'),
 ('List index, under a flag (*If)', r'\.(at|slot|constSlot)If\('),
 ('String/slice index, unproven (rig.at/elemPtr)', r'rig\.(at|elemPtr)\('),
 ('String/slice index, partly or fully proven (rig.atProven)', r'rig\.(atProven|elemPtrProven)\('),
 ('String/slice index, under a flag (rig.atIf)', r'rig\.(atIf|elemPtrIf)\('),
 ('Array index (rig.indexBelow)', r'rig\.indexBelow\('),
 ('Slice s[a..b] (rig.slice)', r'rig\.slice\('),
 ('Byte read/write (rig.readInt etc.)', r'rig\.(readInt|writeInt|simdRead)\('),
 ('Narrowing conversion (@intCast to a narrower or unsigned type)', r'@as\((u8|u16|u32|u64|i8|i16|i32), @intCast\('),
 ('Int + (overflow-checked by Zig)', r'[\w)\]] \+ [\w(@]'),
 ('Int - ', r'[\w)\]] - [\w(@]'),
 ('Int * ', r'[\w)\]] \* [\w(@]'),
 ('+= / -= / *=', r' (\+|-|\*)= '),
 ('+ proven no overflow (rig.addProven)', r'rig\.addProven\('),
 ('+ under a flag (rig.addIf)', r'rig\.addIf\('),
 ('/ and % (divide by zero / overflow)', r'@divTrunc\(|rig\.rem\('),
]
files = sys.argv[1:]
print('| check | ' + ' | '.join(f.split('/')[-1] for f in files) + ' |')
print('|---|' + '---:|' * len(files))
texts = [open(f).read() for f in files]
for name, p in pats:
    r = re.compile(p)
    print('| %s | %s |' % (name, ' | '.join(str(len(r.findall(t))) for t in texts)))
