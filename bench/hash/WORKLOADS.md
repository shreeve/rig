# bench/hash workloads

What every contestant times, exactly, so each program can be written
from this page and their checksums agree. `map.rs` (`rust/src/main.rs`)
is the reference: a new program must print what it prints, check for
check.

## Shared pieces

- `N = 1,000,000`, `TOTAL = 4 * N`, `MUL = -7046029254386353131`.
- `scatter(n)`: splitmix64's output for `n + 1`, on the bits of `n` as
  an unsigned 64-bit integer, read back as a signed one:
  `z = (n + 1) * 0x9e3779b97f4a7c15; z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
  z = (z ^ (z >> 27)) * 0x94d049bb133111eb; z ^ (z >> 31)`, every
  operation wrapping, every shift logical. A bijection, so distinct `n`
  give distinct keys.
- `shuffle(v)`: Fisher-Yates from the end, `for i = len-1 down to 1:
  j = unsigned(scatter(0x5eed + i)) % (i + 1); swap v[i], v[j]`.
- `text(n)`: the decimal of `unsigned(scatter(n)) >> (n % 48)`, then `#`,
  then the decimal of `n`: `text(0)` is "16294208416658607535#0",
  `text(47)` "53789#47". Over a million, 7 to 27 bytes, 19 on average,
  spread evenly from 13 to 25; distinct by the part after `#`.
- `big(i)`: a value of eight 64-bit integers, `i, i+1, ..., i+7`.
- A line is `KEYS OP NS CHECK`. NS is the time of the whole loop in
  nanoseconds, scaled to a million operations: `ns * N / ops`. CHECK is
  an integer every contestant must print alike; sums wrap at 64 bits.
- Arrays of keys, values and lookups are made before the timing starts,
  each in a pass of its own (so one array's texts sit together in
  memory); a map is made empty before it, and dropped after it.

## Rows

**`int{s}`**, s in 16, 1000, 100000, 4000000 (keys `i * MUL`, in
order): as bench/hash's README says. Unchanged since the first round.

**`rnd{s}`**, s in 16, 24, 1000, 1500, 100000, 150000, 3000000, 4000000:
random keys `scatter(n)`. `k = N / s` maps of `s` (or one map when
`s >= N`), `reps = TOTAL / (k * s)` rounds:
- insert: map `j` gets `scatter(j*s + i) -> i`, for `i` in `0..s`;
  CHECK `reps * k * s`;
- remove: each key taken back, in the same order; CHECK the sum of the
  values taken;
- hit: one map of `scatter(i) -> i`, looked up with those keys shuffled
  (one `shuffle`), `TOTAL / s` rounds; CHECK the sum of the values found;
- miss: the same map, keys `scatter(8N + i)`, `i` in `0..s`; CHECK the
  count found (0);
- iterate: the same map walked `TOTAL / s` times; CHECK the sum of its
  values.
The in-between sizes catch each table at another fill: 24 and 1500
just past a doubling, 3000000 just under one.

**`lat{s}` chain**, s in 16, 1000, 100000, 4000000: one lookup at a
time, each waiting for the last. `p` is `0..s` shuffled, and
`next[p[t]] = p[(t+1) % s]`: one cycle through `0..s`. The map holds
`scatter(i) -> scatter(next[i])`, put in order of `i`, so a map that
keeps its entries in order meets them out of the order it walks them.
From `key = scatter(p[0])`, `key = m[key]`, `TOTAL` times. CHECK the
last key.

**`churn{s}` turnover**, s in 16, 1000, 100000, 4000000: a map of
`scatter(i) -> i` for `i` in `0..s`, then, for `t` in `0..TOTAL/2`:
remove `scatter(t)` (present: its value is `t`), then insert
`scatter(s + t) -> s + t`. `TOTAL` operations. CHECK the sum of the
values removed.

**`mix{s}` half**, s in 16, 1000, 100000, 4000000: the map of
`scatter(i) -> i`, `i` in `0..s`, looked up with `L[i] = scatter(i)` for
even `i` and `scatter(8N + i)` for odd `i`, `L` shuffled, `TOTAL / s`
rounds: half hit, in an order no predictor learns. CHECK the sum of the
values found.

**`str{s}`**, s in 16, 1000, 100000, 1000000: text keys, each owned by
the map (moved in, not copied), `N` operations a row. Lookups use equal
texts made apart, so a compare reads two strings. `k = N / s` maps of
`s` (one when `s >= N`), `reps = N / (k * s)`:
- insert: map `j` gets `text(j*s + i) -> i`; CHECK `reps * k * s`;
- remove: each taken back with a text made apart; CHECK the sum of the
  values;
- hit: one map of `text(i) -> i`, looked up with texts made apart,
  shuffled, `N / s` rounds; CHECK the sum;
- miss: texts `text(8N + i)`, `N / s` rounds; CHECK the count (0).
A string row's hash is each table's own string hash in every variant
(`-mix` changes only the hash of integers).

**`big{s}`**, s in 16, 1000, 100000, 1000000: `rnd`'s insert, remove,
hit, and iterate with `big(i)` for the value `i`, `TOTAL` operations a
row; CHECK sums the last field (`i + 7`) for remove and hit, the first
(`i`) for iterate.

**Memory**: run with the argument `mem`, a program makes the keys
`scatter(n)`, `n` in `0..4000000`, in an array, puts each into one map
(`-> n`) and prints `mem 4000000 len LEN`; with `mem0`, it makes only
the array. `bench-hash --mem` reads each run's peak resident memory and
reports `(peak(mem) - peak(mem0)) / 4000000` as bytes per entry.
