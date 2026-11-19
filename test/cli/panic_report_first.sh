# A deadlock among many waiters is reported once, as the deadlock. The
# method `run`, run inline on `main`, waits for a slot in its own actor's
# mailbox, which 1,000 queued calls fill. Its panic ends the actor, which
# answers each queued call as made to an actor that died, so each
# caller panics at that answer on its own worker; and a caller that
# blocks after `run` does finds the same cycle, though it is not on it.
# Every run must name the deadlock: not "the actor died", and not a
# failure of the report itself. A deterministic run (RIG_SEED) has one
# thread, where `run` always reports first, so the case runs unseeded.
# Sixty runs of a release build (about 0.05 s each), where the race is
# found, and five of a debug build under the sanitizer (about 3.5 s
# each), so a report that reads freed memory is found too.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >hub.rig <<'EOF'
obj Hub
  n: Int

  fun get(?@) -> Int
    @n

  fun run(!@, me: *Actor[Hub]) -> Int
    ts = Tasks[Int]()
    for 0..1001
      !ts.add(me.get()&)
    ts.len

sub main()
  h = *Actor(Hub(n: 3), mailbox: 1000)
  print((!h).run(+h))
EOF
rig build -o hub hub.rig >build.log 2>&1 || fail "build hub: $(cat build.log)"
# A file of its own, so the two builds keep a cache each (`rig` in _lib.sh).
cp hub.rig hub_release.rig
rig build --release -o hub-release hub_release.rig >build.log 2>&1 || fail "build hub --release: $(cat build.log)"
report="panic: deadlock: these calls wait on each other, and none can go on: Hub.run -> a slot in Hub's mailbox"
for i in $(seq 1 60); do
    RIG_NO_CRASH_REPORT=1 ./hub-release >/dev/null 2>err.txt
    head -1 err.txt | grep -qF "$report" || fail "release run $i reported: $(head -1 err.txt)"
done
for i in $(seq 1 5); do
    RIG_SANITIZE=1 RIG_NO_CRASH_REPORT=1 ./hub >/dev/null 2>err.txt
    head -1 err.txt | grep -qF "$report" || fail "sanitized run $i reported: $(head -1 err.txt)"
done
exit 0
