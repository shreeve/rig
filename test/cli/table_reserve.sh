# Tables (SPEC §10, "Table"): a table of zeros reserves its slots and
# the system gives each page when it is first touched, so 22 tables of
# 2 GiB, one slot of each written, keep the process small. The same
# programs give the same output with the lowering of a target with no
# lazily zeroed pages (`RIG_TABLE_FALLBACK`, committed as written), and
# `RIG_NO_PROOFS` makes a slot's index a test.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >many.rig <<'EOF2'
N = 1 << 28

sub main()
  tables: List[Table[Int, N]] = List()
  for k in 0..22
    t: Table[Int, N] = Table()
    _ = (!t).push(k)
    if Slot[N].of(N - 1 - k * 4096) as far
      t[far] = k
    !tables.push(<t)
  total = 0
  for t in tables
    total += t[0] + t.len
  print(tables.len, total)
EOF2
rig build --release -o many many.rig >build.log 2>&1 || fail "build many: $(cat build.log)"
case $(uname) in
    Darwin)
        out=$(/usr/bin/time -l ./many 2>time.log) || fail "run many: $(cat time.log)"
        rss=$(awk '/maximum resident set size/ { print $1 }' time.log) ;;
    *)
        out=$(/usr/bin/time -v ./many 2>time.log) || fail "run many: $(cat time.log)"
        rss=$(( $(awk -F: '/Maximum resident set size/ { print $2 }' time.log) * 1024 )) ;;
esac
expect_eq "$out" "22 253" "22 tables of 2 GiB"
(( rss < 64 * 1024 * 1024 )) || fail "22 tables of 2 GiB, one page of each written, took $rss bytes resident"

cat >same.rig <<'EOF2'
obj P
  x: Int = 0
  on: Bool = false

sub main()
  t: Table[P, 100000] = Table()
  a = (!t).push(P(x: 1, on: true))
  b = (!t).push(P(x: 2))
  if Slot[100000].of(99999) as far
    print(t[far].x, t[far].on)
    t[far].x = 9
    print(t[far].x, t.len)
  for p in ?t
    print(p.x)
  print(t[a].on, t[b].x)
EOF2
want=$'0 false\n9 2\n1\n2\ntrue 2'
got=$(rig run same.rig 2>&1) || fail "same: $got"
expect_eq "$got" "$want" "a reserved table"
got=$(RIG_TABLE_FALLBACK=1 rig run same.rig 2>&1) || fail "same, committed: $got"
expect_eq "$got" "$want" "a committed table"

cat >matched.rig <<'EOF2'
sub main()
  t: Table[Int, 100000] = Table()
  s = (!t).push(4)
  w: Table[String, 4] = Table()
  ws = (!w).push(String("ab"))
  if Slot[100000].of(99999) as far
    a = match t[far]
      0 => 10
      n => n
    b = match t[s]
      4 => 40
      n => n
    c = match w[ws]
      "ab" => 1
      x => x.len
    print(a, b, c, t.len)
EOF2
got=$(RIG_TABLE_FALLBACK=1 rig run matched.rig 2>&1) || fail "matched, committed: $got"
expect_eq "$got" "10 40 1 1" "a match on a committed table's slots"

cat >noproofs.rig <<'EOF2'
sub main()
  t: Table[Int, 64] = Table()
  s = (!t).push(3)
  print(t[s])
EOF2
zig=$(rig emit noproofs.rig 2>/dev/null)
expect_has "$zig" "t.at(s)" "a slot's index"
zig=$(RIG_NO_PROOFS=1 rig emit noproofs.rig 2>/dev/null)
expect_has "$zig" "t.atInt(s)" "a slot's index under RIG_NO_PROOFS"

# Spans: the same in a reserved and a committed table, and a span past
# what a committed table has written is read only where it wrote.
cat >spans.rig <<'EOF2'
sub main()
  t: Table[Int, 100000] = Table()
  u: Table[Int, 100000] = Table()
  _ = (!t).push(1)
  a = (!t).append([2, 3, 4])
  for x in !t[a]
    x += 10
  e: Span[100000] = Span()
  print(?t[a], a.sub(1, 2), (?u[e]).len, (?u[a.sub(0, 0)]).len)
EOF2
want='[12, 13, 14] 2..3 0 0'
got=$(rig run spans.rig 2>&1) || fail "spans: $got"
expect_eq "$got" "$want" "spans of a reserved table"
got=$(RIG_TABLE_FALLBACK=1 rig run spans.rig 2>&1) || fail "spans, committed: $got"
expect_eq "$got" "$want" "spans of a committed table"

cat >past.rig <<'EOF2'
sub main()
  t: Table[Int, 100000] = Table()
  u: Table[Int, 100000] = Table()
  a = (!t).append([2, 3, 4])
  print(?u[a])
EOF2
got=$(rig run past.rig 2>&1) || fail "past: $got"
expect_eq "$got" "[0, 0, 0]" "a span of another reserved table"
if got=$(RIG_TABLE_FALLBACK=1 rig run past.rig 2>&1); then fail "past, committed, ran: $got"; fi
expect_has "$got" "a span past the slots this table has written" "a span of another committed table"
zig=$(rig emit spans.rig 2>/dev/null)
expect_has "$zig" "t.viewMut(a)" "a span's view"
zig=$(RIG_NO_PROOFS=1 rig emit spans.rig 2>/dev/null)
expect_has "$zig" "t.viewMutTested(a)" "a span's view under RIG_NO_PROOFS"
