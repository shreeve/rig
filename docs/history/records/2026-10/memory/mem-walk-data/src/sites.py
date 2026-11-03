# sites.py ERR: the heap profile's sites (RIG_HEAP_PROFILE=sites, top 120 at the peak), each
# as MiB, blocks, owner, and its first program calls, filtered to OWNER if given.
import sys, re
txt = open(sys.argv[1]).read(); want = sys.argv[2] if len(sys.argv) > 2 else None
skip = {"reserveOne", "insertHashed", "insertSmallSlow", "put", "set", "push", "reserveTotal", "grow", "ensure_room"}
for b in re.split(r"\n#\d+: ", txt)[1:]:
    head, *calls = b.strip().split("\n")
    m = re.match(r"([\d.]+) MiB, [\d.]+%, (\d+) blocks of (.+?), made in", head)
    if not m: continue
    mib, n, owner = float(m.group(1)), int(m.group(2)), m.group(3)
    if want and not owner.startswith(want): continue
    cs = [c.strip().split(" (")[0] for c in calls if c.strip()]
    cs = [c for c in cs if c not in skip]
    print(f"{mib:6.2f} {n:7d} {owner[:48]:48s} {' < '.join(cs[:3])[:110]}")
