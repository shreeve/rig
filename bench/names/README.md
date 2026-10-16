# Name lookup benchmark

Times `rig.NameTable.find` (`src/runtime.zig`), the lookup behind
`E.from_text(word)`, against comparing the names one by one. The table
is built by `src/nametable.zig`, as the compiler builds it. It is not
part of the test suite or CI.

```sh
D=$(mktemp -d)
cpuq run --cores 2 -- zig build-exe -O ReleaseSafe --dep nametable \
  -Mroot=bench/names/lookup.zig -Mnametable=src/nametable.zig -femit-bin=$D/lookup
cpuq run --cores 1 -- $D/lookup
```

For each count of names, 3 to 12 random lowercase letters and `_`, it
looks up 4,096 words 400 times and prints `NAMES WAY OP NS`: the
nanoseconds of one lookup that hits (a name of the set) or misses (a
word of a name's length that is not one), the fastest of seven runs.
Each word sits in a buffer of its own, as a word read from input does.

## Results

Apple Silicon (arm64), Zig 0.17.0, 2026-10-16, on a shared machine
(load 6 to 8 of 10 cores), ns per lookup. ReleaseSafe is what
`rig build --release` makes; ReleaseFast is `--release=fast`:

| Names | Mode | One by one, hit | One by one, miss | Table, hit | Table, miss |
|---|---|---|---|---|---|
| 2 | safe | 3.1 | 4.0 | 5.1 | 3.2 |
| 3 | safe | 3.1 | 4.7 | 4.5 | 3.1 |
| 4 | safe | 4.1 | 7.4 | 4.6 | 2.9 |
| 8 | safe | 6.9 | 11.7 | 4.7 | 3.4 |
| 16 | safe | 12.4 | 20.0 | 4.3 | 3.4 |
| 64 | safe | 39.7 | 66.4 | 4.7 | 3.6 |
| 256 | safe | 140.8 | 263.8 | 5.1 | 3.9 |
| 3 | fast | 1.9 | 5.9 | 3.5 | 1.7 |
| 8 | fast | 3.4 | 7.6 | 4.3 | 2.2 |
| 16 | fast | 4.5 | 12.0 | 3.0 | 2.4 |
| 64 | fast | 21.2 | 35.6 | 3.7 | 2.7 |
| 256 | fast | 86.9 | 177.4 | 3.4 | 2.6 |

Comparing one by one wins a hit among a few names, by 1 to 2 ns, up to
about 4 names (safe) or 8 (fast). The table wins every miss, at every
size, by 1 to 4 ns among a few names and by far more among many; and a
miss is the common case for a word read from input. So every enum gets
the table, of at least 16 slots: one rule, and one path through `find`.
A smaller table of three names probed longer runs; at 16 slots its hits
cost what four names' do.
