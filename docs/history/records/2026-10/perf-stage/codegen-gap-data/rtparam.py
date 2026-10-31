# In each emitted module, an inline function's object parameter is taken
# as it comes (`const n = __rig_in_n;`), not through `rig.rt`, whose call
# wrote the object to a temporary in parts that was then read whole.
# Objects only: a parameter whose type is a named object, enum or union
# (an identifier, possibly qualified, starting with a capital letter).
import re, glob, collections
n = collections.Counter()
for p in glob.glob("*.zig"):
    lines = open(p).read().split("\n"); sig = ""
    for i, l in enumerate(lines):
        if re.search(r"\bfn \w+\(", l): sig = l
        m = re.match(r"(\s*)const (\w+) = rig\.rt\(__rig_in_(\w+)\);$", l)
        if m and m.group(2) == m.group(3):
            t = re.search(r"__rig_in_%s: ([\w.]+)[,)]" % re.escape(m.group(2)), sig)
            if t and re.match(r"([a-z_]\w*\.)*[A-Z]\w*$", t.group(1)):
                lines[i] = f"{m.group(1)}const {m.group(2)} = __rig_in_{m.group(2)};"
                n[t.group(1)] += 1
    open(p, "w").write("\n".join(lines))
print(sum(n.values()), "parameters;", n.most_common(12))
