import sys, re, collections
tsv, ips = sys.argv[1], sys.argv[2]
T = sum(1 for l in open(ips) if l.strip())
cats = [
 ("check helper (index, indexBelow, okBelow, offset*, provenOffset)", r"runtime\.(index|indexBelow|okBelow|offsetBelow|offsetIf|provenOffset|heldIndex|heldLen|bounds|lenOf)\b|runtime\.index__"),
 ("yield (turn, tickCall, sched flag)", r"runtime\.(turn|tickCall)|atomic\.Value\(u(8|32)\)\.load"),
 ("Map (ordered.zig, unordered.zig)", r"^ordered\.zig|^unordered\.zig"),
 ("Table (table.zig)", r"^table\.zig"),
 ("List element ops (runtime ListOf)", r"runtime\.ListOf"),
 ("key/eq helpers (eqlAs)", r"runtime\.eqlAs"),
 ("rt identity", r"runtime\.rt__|runtime\.rt$"),
 ("drop, clone", r"__rig_drop|runtime\.drop|cloneValue|runtime\.take"),
 ("String", r"runtime\.String"),
 ("enum conversion", r"enums\.fromInt"),
 ("alloc, free", r"^alloc\.zig"),
 ("memcpy, memset, memmove", r"memcpy|memset|memmove"),
 ("mem.eqlBytes (string compare)", r"mem\.eql"),
 ("blocking pool / sched", r"^sched\.zig"),
 ("other runtime.zig", r"^runtime\.zig"),
 ("Trig code (checker, binder, parser, ast, ...)", r"."),
]
c = collections.Counter()
for l in open(tsv):
    n, f, fn, outer = l.rstrip("\n").split("\t")
    key = f + "\t" + fn
    for name, rx in cats:
        if re.search(rx, fn) or re.search(rx, key.replace("\t"," ")) and rx.startswith("^"):
            c[name] += int(n); break
for name, _ in cats: print(f"{100*c[name]/T:6.2f}%  {name}")
