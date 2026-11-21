# No string in the compiler says lend, lent, read loan or write loan: a
# sigil on a place makes a view, a read view or a write view (AGENTS.md,
# "One vocabulary"). Every string literal in src/*.zig is read: messages,
# test names, and the Zig that emit writes.
source "$ROOT/test/cli/_lib.sh"

out=$(python3 - "$ROOT/src" <<'PY'
import glob, os, re, sys
words = re.compile(r"\b(lend|lends|lending|lent|read loan|write loan|exclusive loan)\b", re.I)

def literals(line):
    """The string literals of a line of Zig, its comment left out."""
    i = 0
    while i < len(line):
        if line.startswith('//', i):
            return
        if line.startswith('\\\\', i):
            yield line[i + 2:]
            return
        if line[i] == "'":
            j = line.find("'", i + 1 + (line[i + 1] == '\\'))
            i = (j if j > 0 else len(line)) + 1
            continue
        if line[i] == '"':
            j, text = i + 1, ''
            while j < len(line) and line[j] != '"':
                text += line[j:j + 2] if line[j] == '\\' else line[j]
                j += 2 if line[j] == '\\' else 1
            yield text
            i = j + 1
            continue
        i += 1

for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.zig'))):
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        for text in literals(line):
            if words.search(text):
                print(f'{os.path.basename(path)}:{n}: {text.strip()}')
PY
)
[[ -z $out ]] || fail "a message says lend or loan:
$out"
