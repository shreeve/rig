# BigInt benchmark

Times `std.bigint` against Trig's port of Go's `math/big`, its 32-bit
limbs, copied verbatim into `bench.rig` from
`trig/src/jsnum/gostd.rig` (Trig b2d44c7). The port has no add or
shl; the port's versions of those two in `bench.rig` were written for
this benchmark, not taken from Trig, so their rows say less than the
others. It is not part of the test suite or CI.

```sh
D=$(mktemp -d)
cpuq run --cores 2 -- bin/rig build --release -o $D/bench bench/bigint/bench.rig
cpuq run --cores 1 -- $D/bench
```

On x86, time on pup under the bench lease, pinned to one core:

```sh
cpuq lease pup-bench --exclusive -- taskset -c 2 $D/bench
```

For each size, 1 to 64 limbs of 64 bits (19 decimal or 16 hexadecimal
digits a limb), it makes 8 random numbers and times each operation over
them in turn, so no two calls in a row see the same input. Each line is
`OP SIZE PORT_NS STD_NS SPEED`: the nanoseconds of one call, the fastest
of seven runs of at least 20 ms each, and how much faster std is. `pow`
raises 8 bases next to the one named; `pow_f64` adds the nearest `F64`,
which the port reaches through a 256-bit float and std directly. Every
operation includes making its result, so add, mul, shl, shr, and pow
each include one allocation, and text one String.

## Results

`rig build --release` (ReleaseSafe), Zig 0.17.0, 2026-10-16. arm64 is
an Apple Silicon Mac, shared (load 8 to 10 of 10 cores); x86 is pup
under the `pup-bench` lease, on core 2. The arm64 shl 1L row varies
between runs: a second run measured it 81% faster.

| Operation | Size | arm64 port ns | arm64 std ns | arm64 std is | x86 port ns | x86 std ns | x86 std is |
|---|---|---|---|---|---|---|---|
| parse10 | 1L | 52 | 22 | 130% faster | 52 | 33 | 56% faster |
| parse16 | 1L | 40 | 28 | 41% faster | 40 | 35 | 12% faster |
| text | 1L | 54 | 23 | 137% faster | 78 | 34 | 127% faster |
| add | 1L | 11 | 9 | 16% faster | 26 | 18 | 40% faster |
| mul | 1L | 12 | 11 | 10% faster | 22 | 19 | 17% faster |
| shl | 1L | 47 | 10 | 344% faster | 38 | 24 | 58% faster |
| shr | 1L | 9 | 8 | 10% faster | 19 | 18 | 7% faster |
| to_f64 | 1L | 28 | 0 | 3622% faster | 54 | 1 | 4861% faster |
| parse10 | 2L | 122 | 35 | 246% faster | 103 | 55 | 85% faster |
| parse16 | 2L | 89 | 45 | 96% faster | 79 | 53 | 49% faster |
| text | 2L | 85 | 40 | 110% faster | 110 | 46 | 134% faster |
| add | 2L | 12 | 10 | 18% faster | 26 | 19 | 38% faster |
| mul | 2L | 33 | 14 | 130% faster | 48 | 20 | 134% faster |
| shl | 2L | 20 | 11 | 82% faster | 39 | 24 | 61% faster |
| shr | 2L | 11 | 8 | 23% faster | 20 | 18 | 12% faster |
| to_f64 | 2L | 76 | 1 | 4437% faster | 85 | 2 | 3527% faster |
| parse10 | 4L | 320 | 61 | 421% faster | 288 | 102 | 182% faster |
| parse16 | 4L | 239 | 76 | 214% faster | 217 | 87 | 147% faster |
| text | 4L | 164 | 77 | 112% faster | 179 | 82 | 118% faster |
| add | 4L | 25 | 12 | 105% faster | 47 | 20 | 132% faster |
| mul | 4L | 77 | 18 | 318% faster | 100 | 25 | 287% faster |
| shl | 4L | 32 | 13 | 143% faster | 59 | 24 | 138% faster |
| shr | 4L | 23 | 11 | 106% faster | 40 | 19 | 113% faster |
| to_f64 | 4L | 184 | 1 | 10219% faster | 156 | 2 | 6492% faster |
| parse10 | 16L | 2453 | 248 | 889% faster | 2579 | 386 | 567% faster |
| parse16 | 16L | 2561 | 331 | 672% faster | 2121 | 319 | 564% faster |
| text | 16L | 1074 | 462 | 132% faster | 994 | 570 | 74% faster |
| add | 16L | 68 | 18 | 271% faster | 94 | 29 | 217% faster |
| mul | 16L | 667 | 173 | 283% faster | 819 | 187 | 337% faster |
| shl | 16L | 67 | 19 | 244% faster | 108 | 32 | 233% faster |
| shr | 16L | 62 | 15 | 304% faster | 97 | 29 | 235% faster |
| to_f64 | 16L | 745 | 1 | 43019% faster | 511 | 2 | 21263% faster |
| parse10 | 64L | 38663 | 1740 | 2121% faster | 39450 | 1809 | 2080% faster |
| parse16 | 64L | 36318 | 1698 | 2037% faster | 35017 | 1492 | 2246% faster |
| text | 64L | 21433 | 6213 | 244% faster | 16518 | 7687 | 114% faster |
| add | 64L | 155 | 62 | 150% faster | 185 | 54 | 238% faster |
| mul | 64L | 13437 | 3048 | 340% faster | 11038 | 2890 | 281% faster |
| shl | 64L | 147 | 44 | 228% faster | 194 | 73 | 163% faster |
| shr | 64L | 150 | 46 | 223% faster | 231 | 49 | 367% faster |
| to_f64 | 64L | 815 | 1 | 45775% faster | 590 | 1 | 29461% faster |
| pow | 10^22 | 699 | 50 | 1295% faster | 1371 | 83 | 1541% faster |
| pow_f64 | 10^22 | 827 | 57 | 1331% faster | 1416 | 86 | 1546% faster |
| pow | 3^100 | 803 | 63 | 1163% faster | 1445 | 93 | 1443% faster |
| pow_f64 | 3^100 | 1078 | 76 | 1318% faster | 1618 | 95 | 1595% faster |
| pow | 7^500 | 1677 | 261 | 541% faster | 2222 | 267 | 731% faster |
| pow_f64 | 7^500 | 2329 | 289 | 705% faster | 2762 | 270 | 920% faster |
| pow | 123^1000 | 14208 | 3020 | 370% faster | 11790 | 2772 | 325% faster |
| pow_f64 | 123^1000 | 15566 | 2921 | 432% faster | 12487 | 2771 | 350% faster |

Times are whole nanoseconds, so a 0 is under 1 ns: std's `to_f64` reads
the top two limbs and the rest only until it finds a set bit, where the
port rounds a copy of the number twice and then doubles the result once
for each bit it dropped.
