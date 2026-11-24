#!/usr/bin/env python3
# static_census.py ZIG...: static count of the checks left in emitted Zig, by category (classify.py's rules
# applied line by line: index ops, narrowing conversions, slices, overflow-checked + - * and += -=).
import sys, re, collections, importlib.util, os
spec = importlib.util.spec_from_file_location('cl', os.path.join(os.path.dirname(__file__), 'classify.py'))
src = open(spec.origin).read().split('\nrows = []')[0]
cl = {}; exec(compile(src, 'classify', 'exec'), cl)
fnre = re.compile(r'^\s*(?:pub )?(?:inline )?fn (\w+)\(')
objre = re.compile(r'^pub const (\w+) = struct|^const (\w+) = struct')
conv = re.compile(r'@as\((u8|u16|u32|i8|i16|i32|u64), @intCast\(')
slic = re.compile(r'rig\.slice(Mut)?\(')
ovf = re.compile(r'[\w)\]] (\+|-|\*) [\w(@]| (\+|-|\*)= ')
tot = collections.defaultdict(collections.Counter)
for path in sys.argv[1:]:
    mod = os.path.basename(path)[:-4]; obj = None; fn = '?'
    for no, line in enumerate(open(path), 1):
        m = objre.match(line)
        if m: obj = m.group(1) or m.group(2)
        m = fnre.match(line)
        if m: fn = m.group(1)
        helper = '%s.%s%s' % (mod, (obj + '.') if obj and line.startswith('    ') else '', fn)
        t = line.strip()
        counts = {'index': len(cl['ops_index'](t)), 'conv': len([x for x in conv.findall(t) if x != 'u64']) + len([1 for x in re.findall(r'@as\(u64, @intCast\(@as\(i64', t)]),
                  'slice': len(slic.findall(t)), 'ovf': len(ovf.findall(t)) - len(re.findall(r'(addProven|addIf)', t))}
        for k, n in counts.items():
            if n <= 0: continue
            for c, f in cl['classify'](helper, k, str(no), t): tot[mod][(c, k)] += n * f
cats = sorted({c for m in tot for c, _ in tot[m]})
print('| category | ' + ' | '.join(tot) + ' |'); print('|---|' + '---:|' * len(tot))
for c in cats:
    print('| %s | %s |' % (c, ' | '.join('%.0f' % sum(v for (cc, k), v in tot[m].items() if cc == c) for m in tot)))
print('| all | %s |' % ' | '.join('%.0f' % sum(tot[m].values()) for m in tot))
