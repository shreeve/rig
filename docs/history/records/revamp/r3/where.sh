#!/bin/bash
# where.sh: print `pup` or `mac`, the machine a heavy run (gates, corpus,
# matrix) should use now. pup when it answers within 15 s, its cpuq has
# no exclusive holder or waiter (a timing window, also through a lease),
# its memory pressure is normal, and it has at least WHERE_MIN_GB
# (default 12) of memory available; else mac. The reason goes to stderr.
#
#   [ "$(where.sh)" = pup ] && pup-gates.sh B logs/B-pup || heavy.sh gates.sh "$W" logs/B
PUP_HOST=${PUP_HOST:-pup}
MIN=${WHERE_MIN_GB:-12}
out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$PUP_HOST" \
    'PATH=$HOME/.local/bin:$PATH; cpuq status --json --no-usage && echo @@ && awk "/^MemAvailable:/ { print int(\$2 / 1048576) }" /proc/meminfo' 2>/dev/null)
if [ -z "$out" ]; then
    echo "where.sh: $PUP_HOST did not answer" >&2
    echo mac; exit 0
fi
printf '%s' "$out" | python3 -c '
import json, sys
text = sys.stdin.read()
status, _, mem = text.partition("@@")
try:
    s = json.loads(status)
    avail = int(mem.strip())
except ValueError:
    print("where.sh: cannot read pup'"'"'s cpuq status", file=sys.stderr); print("mac"); sys.exit()
def jobs():
    for j in s.get("holders", []) + s.get("waiters", []):
        yield j
    for lease in s.get("leases", []):
        for j in lease.get("holders", []) + lease.get("waiters", []):
            yield j
excl = [j.get("label") or str(j.get("pid")) for j in jobs() if j.get("exclusive")]
min_gb = int(sys.argv[1])
if excl:
    why = "exclusive: " + ", ".join(sorted(set(excl)))
elif s.get("memory_pressure") != "normal":
    why = "memory pressure " + str(s.get("memory_pressure"))
elif avail < min_gb:
    why = "%d GB available, under %d" % (avail, min_gb)
else:
    print("where.sh: pup free (%d of %d cores held, %d GB available)" % (s.get("held", 0), s.get("budget", 0), avail), file=sys.stderr)
    print("pup"); sys.exit()
print("where.sh: pup busy (%s)" % why, file=sys.stderr)
print("mac")
' "$MIN"
