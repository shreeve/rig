"""The agreement test's two steps (test/cli/agree.sh).

    _agree.py list TESTS EXAMPLES   the programs worth exporting, `name<TAB>path`
    _agree.py compare JUDGED LIST   compare the verdicts; exit 1 on a failure

`list` keeps a program only when it could be in λRig's scope: one
`sub main()` and nothing else at the left margin, with no text, member,
index, type, or block. `rig-oracle --lambda` decides the scope exactly;
this only saves it loading programs that are plainly outside.

`compare` reads lrig's lines, `name<TAB>rig<TAB>program<TAB>lambda<TAB>run`,
where `rig` is `accept` or `reject` and the first error, `lambda` is
`accept` or `reject`, and `run` is `ok` or λRig's fault. Its kinds:

- `agree`: both accept, or both reject;
- `unsound`: the compiler accepts and λRig's run faults. Always a
  failure, never listed;
- `rig-stricter`: the compiler rejects what λRig accepts, which λRig
  proves runs clean (`accepts_runs`);
- `lambda-stricter`: λRig rejects what the compiler accepts, and its run
  is clean.

The last two fail unless the list (test/oracle/agreement) has the
program with that kind, `program kind class note...`; an entry whose
program agrees now, or is gone, fails too.
"""
import os
import re
import sys

SKIP = re.compile(r'["\'.\[\]:{}`@&|$]|\b(if|for|while|match|loop|return|defer|fun|obj|enum|use|new|test|break|continue)\b')


def listing(tests, examples):
    found = []
    for base, label in ((tests, ''), (examples, 'examples/')):
        for d, _, files in os.walk(base):
            for f in files:
                if not f.endswith('.rig'):
                    continue
                path = os.path.join(d, f)
                rel = label + os.path.relpath(path, base)
                text = open(path, encoding='utf-8', errors='replace').read()
                lines = [l for l in text.split('\n') if l.strip() and not l.lstrip().startswith('#')]
                if not lines or lines[0].rstrip() != 'sub main()':
                    continue
                if any(not l.startswith(' ') for l in lines[1:]):
                    continue
                if any(SKIP.search(l) for l in lines[1:]):
                    continue
                found.append((rel, path))
    for rel, path in sorted(found):
        print(f'{rel}\t{path}')


def compare(judged, listed):
    entries = {}
    for line in open(listed, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'):
            continue
        words = line.split()
        if len(words) < 3:
            print(f'{listed}: a line that is not `program kind class note...`: {line}')
            return 1
        if words[1] == 'unsound':
            print(f'{listed}: {words[0]} lists an `unsound` program; those always fail')
            return 1
        entries[words[0]] = [words[1], words[2], False]
    counts = {}
    outside = {}
    failures = 0
    for line in open(judged, encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if len(f) == 3:
            why = f[2][len('outside '):] if f[2].startswith('outside') else f[2]
            outside[why] = outside.get(why, 0) + 1
            continue
        if len(f) != 5:
            print(f'agree: an unexpected line from lrig: {line.rstrip()}')
            failures += 1
            continue
        name, rig, _, lam, run = f
        rig_ok = rig == 'accept'
        lam_ok = lam == 'accept'
        if lam_ok and run != 'ok':
            print(f'BROKEN {name}: λRig accepts it and its run ends at {run}: lrig is not λRig')
            failures += 1
            continue
        if rig_ok and run != 'ok':
            kind = 'unsound'
        elif rig_ok == lam_ok:
            kind = 'agree'
        elif lam_ok:
            kind = 'rig-stricter'
        else:
            kind = 'lambda-stricter'
        counts[kind] = counts.get(kind, 0) + 1
        if kind == 'agree':
            if name in entries:
                print(f'FIXED {name}: listed as {entries[name][0]}, but the checkers agree now; remove it from {listed}')
                failures += 1
                entries[name][2] = True
            continue
        if kind == 'unsound':
            print(f'UNSOUND {name}: the compiler accepts it, and λRig\'s run ends at {run}: {f[2]}')
            failures += 1
            continue
        e = entries.get(name)
        if e and e[0] == kind:
            e[2] = True
            continue
        print(f'{kind.upper()} {name}: rig {rig}; λRig {lam}, run {run}: {f[2]}')
        failures += 1
    for name, e in entries.items():
        if not e[2]:
            print(f'STALE {name}: listed as {e[0]} in {listed}, but not in the corpus now')
            failures += 1
    scope = sum(counts.values())
    print(f'agree: {scope} programs in λRig\'s scope, {sum(outside.values())} outside; '
          + ', '.join(f'{counts.get(k, 0)} {k}' for k in ('agree', 'rig-stricter', 'lambda-stricter', 'unsound')))
    if os.environ.get('AGREE_STATS'):
        for why, n in sorted(outside.items(), key=lambda x: -x[1]):
            print(f'{n:6}  outside: {why}')
    return 1 if failures else 0


if __name__ == '__main__':
    if sys.argv[1] == 'list':
        listing(sys.argv[2], sys.argv[3])
    else:
        sys.exit(compare(sys.argv[2], sys.argv[3]))
