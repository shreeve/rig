# `test/run --shard I/N` and `test/matrix.py --shard I/N` split the tests
# they select into N disjoint shards that together run them all.
source "$ROOT/test/cli/_lib.sh"

ids() { sed -nE 's/^ *(pass|ok|rejected) +([^ ]+).*/\2/p' | sort; }
out=$(RIG_TEST_OUT=$PWD/out "$ROOT/test/run" -v examples 2>&1 | ids)
[[ $(wc -l <<<"$out") -ge 3 ]] || fail "too few examples to shard: $out"
: >shards
for i in 1 2 3; do
  o=$(RIG_TEST_OUT=$PWD/out$i "$ROOT/test/run" -v --shard $i/3 examples 2>&1) || fail "shard $i/3: $o"
  ids <<<"$o" >>shards
done
expect_eq "$(sort shards)" "$out" "the shards of the examples"

for bad in 0/3 4/3 3 x/2; do
  o=$(RIG_TEST_OUT=$PWD/bad "$ROOT/test/run" --shard $bad examples 2>&1); expect_rc $? 2 "--shard $bad"
done

out=$(python3 "$ROOT/test/matrix.py" -v -k int.print 2>&1 | ids)
[[ $(wc -l <<<"$out") -ge 3 ]] || fail "too few matrix cells to shard: $out"
: >cells
for i in 1 2; do
  o=$(python3 "$ROOT/test/matrix.py" -v -k int.print --shard $i/2 2>&1) || fail "matrix shard $i/2: $o"
  ids <<<"$o" >>cells
done
expect_eq "$(sort cells)" "$out" "the shards of the matrix"
python3 "$ROOT/test/matrix.py" --shard 3/2 >/dev/null 2>&1; expect_rc $? 2 "matrix --shard 3/2"
python3 "$ROOT/test/matrix.py" --oracle --shard 1/2 >/dev/null 2>&1; expect_rc $? 2 "matrix --oracle --shard 1/2"
exit 0
