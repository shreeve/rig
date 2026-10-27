# A deadlock among many waiters is reported once, as the deadlock. The
# method `run`, run inline on `main`, waits for a slot in its own actor's
# mailbox, which 1,000 queued calls fill. Its panic ends the actor, which
# answers each queued call as made to an actor that died, so each
# caller panics at that answer on its own worker; and a caller that
# blocks after `run` does finds the same cycle, though it is not on it.
# Every run must name the deadlock: not "the actor died", and not a
# failure of the report itself. A deterministic run (RIG_SEED) has one
# thread, where `run` always reports first, so the case runs unseeded.
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
for i in $(seq 1 60); do
    RIG_SANITIZE=1 RIG_NO_CRASH_REPORT=1 ./hub >/dev/null 2>err.txt
    head -1 err.txt | grep -qF "panic: deadlock: these calls wait on each other, and none can go on: Hub.run -> a slot in Hub's mailbox" ||
        fail "run $i reported: $(head -1 err.txt)"
done
exit 0
