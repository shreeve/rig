#!/usr/bin/env python3
"""group.py TSV...: samples (count, innermost file, innermost function,
outermost function, from attr.py) grouped by the innermost frame: the
code a sampled instruction came from, inlined or not. Rig's groups are
the runtime, std, and the Zig std and compiler_rt that Rig's emitted code
calls; Trig's are its own modules."""
import sys, re, collections
TRIG_FILES = {'checker.zig', 'ast.zig', 'parser.zig', 'binder.zig', 'lexer.zig', 'compiler.zig', 'core.zig',
              'jsnum.zig', 'tspath.zig', 'printer.zig', 'diagnostics.zig', 'scanner.zig', 'tsoptions.zig',
              'stringutil.zig', 'collections.zig', 'locale.zig', 'semver.zig', 'glob.zig', 'bundled.zig',
              'main.zig', 'progress.zig', 'portmap.zig', 'testcase.zig', 'module.zig', 'outputpaths.zig'}
def group(f, fn):
    if f == 'ordered.zig' or f == 'wyhash.zig' or re.search(r'runtime\.(hashWord|hashWords|foldMul|hashMix|hashBytes|eqlAs)', fn):
        return ('Rig', 'Map/Set (ordered.zig, hashing)')
    if f == 'table.zig':
        return ('Rig', 'Table reads and pushes (table.zig)')
    if f in ('alloc.zig', 'Allocator.zig'):
        return ('Rig', 'allocator (alloc.zig)')
    if f in ('memcpy.zig', 'memset.zig', 'compiler_rt.zig', 'stack_probe.zig', 'memmove.zig'):
        return ('Rig', 'memcpy, memset, stack probes (compiler_rt)')
    if re.search(r'runtime\.(turn|tickCall)|atomic\.Value', fn) or f == 'sched.zig':
        return ('Rig', 'yield checks (turn, tickCall)')
    if re.search(r'runtime\.(index|indexBelow|offsetBelow|okBelow|provenOffset|offsetIf|bounds|at__|atIf)\b|^math\.cast|runtime\.(index|bounds|at)__func', fn) or f == 'math.zig':
        return ('Rig', 'index and range checks')
    if f == 'enums.zig':
        return ('Rig', 'enum from integer (std.enums.fromInt)')
    if re.search(r'runtime\.ListOf\(', fn):
        return ('Rig', 'List operations (push, pop, at, mem, grow)')
    if f == '__rig_std_text.zig' or re.search(r'runtime\.(String|Str)', fn) or f in ('mem.zig', 'unicode.zig', 'utf8.zig', 'fmt.zig'):
        if 'Interner' in fn:
            return ('Rig', 'interner (std.text Interner)')
        return ('Rig', 'String and text (std.text, mem.eql)')
    if f == 'runtime.zig':
        return ('Rig', 'other runtime (lend, rt, niches, drops)')
    if f.startswith('__rig_std_'):
        return ('Rig', 'other std (' + f[len('__rig_std_'):-4] + ')')
    if f in TRIG_FILES or not f.startswith('?'):
        if f in TRIG_FILES: return ('Trig', "Trig's own code (" + f + ')')
        return ('Rig?', 'other Zig std (' + f + ')')
    return ('?', 'unsymbolized')
for path in sys.argv[1:]:
    c = collections.Counter(); side = collections.Counter(); tot = 0
    for line in open(path):
        n, f, fn, outer = line.rstrip('\n').split('\t')
        n = int(n); tot += n
        s, g = group(f, fn); c[(s, g)] += n; side[s] += n
    print(f'\n### {path} ({tot} samples)')
    for s, n in side.most_common(): print(f'{s}: {100 * n / tot:.1f}%')
    print('| side | group | share of cycles |\n|---|---|---:|')
    for (s, g), n in c.most_common(): print(f'| {s} | {g} | {100 * n / tot:.2f}% |')
