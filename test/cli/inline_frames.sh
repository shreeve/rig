# timeout: 900
# Rig's count of each frame (`rig check --facts=frames`) against the stack
# Zig's code actually reserves, for functions that inline marked `inline`
# functions in every way a call can (a chain, generic instances, a
# compile-time value, a method directly and through a box, an iterator),
# in debug and --release: a count lower than the real frame fails. The
# real frame is the prologue's stack reservation, read from the assembly
# Zig writes for aarch64, so the test runs on an aarch64 Mac only.
source "$ROOT/test/cli/_lib.sh"

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "skipped: reads aarch64 assembly"
    exit 0
fi

cat >ev.rig <<'RIG'
inline fun big(i: Int) -> Int
  t = [100000 of 0]
  for k in 0..100000
    t[k] = k * i
  t[(i * 7 + 1) % 100000]

inline fun mid(i: Int) -> Int
  big(i) + big(i + 1)

inline fun gen[T](x: T, i: Int) -> Int
  t = [50000 of 0]
  for k in 0..50000
    t[k] = k + i
  u = [x, x, x, x]
  t[(i * 3 + 2) % 50000] + 4

inline fun bign[n: Int](i: Int) -> Int
  t = [80000 of n]
  for k in 0..80000
    t[k] += k * i
  t[(i * 5) % 80000]

obj G[T]
  v: T

  inline fun deep(?self, i: Int) -> Int
    t = [60000 of 0]
    for k in 0..60000
      t[k] = k - i
    t[(i * 11) % 60000]

obj Count
  n: Int

  inline fun next(!self) -> Int?
    t = [40000 of 0]
    for k in 0..40000
      t[k] = k + self.n
    self.n += 1
    return none if self.n > 2
    t[(self.n * 13) % 40000]

called sub chain(i: Int)
  print(mid(i) + big(i))

called sub generic(i: Int)
  print(gen(1, i) + gen(true, i))

called sub values(i: Int)
  print(bign[1](i) + bign[2](i))

called sub method(i: Int)
  g = G[Int](v: 1)
  b = ^G[Int](v: 2)
  print(g.deep(i) + b.deep(i))

called sub loop()
  c = Count(n: 0)
  for x in !c
    print(x)

sub main()
  chain(1)
  generic(1)
  values(1)
  method(1)
  loop()
RIG
out=$(rig run ev.rig 2>&1) || fail "run: $out"
expect_eq "$out" $'46\n20\n13\n20\n13\n27' "run"
counted=$(rig check --facts=frames ev.rig) || fail "facts: $counted"
rig emit ev.rig >/dev/null 2>&1 || fail "emit"
pkg=$RIG_OUT_DIR/programs/ev
for mode in Debug ReleaseSafe; do
    (cd "$pkg" && "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../ev-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode asm: $(cat build.log)"
    for fn in chain generic values method loop; do
        est=$(awk -v f="\`$fn\`" '$2 == f { print $3 }' <<<"$counted")
        [[ -n $est && $est -gt 0 ]] || fail "$fn: no count in: $counted"
        # The prologue: each `sub sp, sp, #N` (`, lsl #12` scales it by
        # 4096) and the pair pushed with `stp ..., [sp, #-N]!`.
        real=$(awk -v f="___rig_main.$fn:" '$0 == f { p = 1 } p { print } p && /\.cfi_endproc/ { exit }' "$pkg/../ev-$mode.s" |
            awk '$1 == "sub" && $2 == "sp," && $3 == "sp," { n = substr($4, 2) + 0; t += ($6 == "#12") ? n * 4096 : n }
                 $1 == "stp" && $4 ~ /^\[sp,$/ && $5 ~ /^#-[0-9]+\]!$/ { gsub(/[#\]!-]/, "", $5); t += $5 + 0 }
                 END { print t + 0 }')
        [[ $real -gt 0 ]] || fail "$mode $fn: no prologue found"
        # A few hundred bytes of saved registers and spills above the
        # count; a missed inlined function is far more.
        (( real <= est + 4096 )) || fail "$mode $fn: Zig reserves $real bytes, Rig counts $est"
    done
done
true
