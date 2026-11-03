# Idiom and beauty review: Benchmarks Game, batch 2 (2026-10-29)

fasta, revcomp, knucleotide, binarytrees, each `{name}.rig` and `{name}-fast.rig`, read beside
the Rust each follows. `bin/rig` at main `1b2f4b59d`.

**How each change was probed.** The file was copied to a temp dir and changed there, then built
`--release=fast`. Its output had to be byte-identical to the Benchmarks Game `*_out` at the small
size (fasta 1000, revcomp and knucleotide on their `*-input1000.txt`, binarytrees 10) and to the
current port's output at a medium size (fasta 2,500,000, whose output is the medium input of
revcomp and knucleotide; binarytrees 18). fasta was also checked redirected to a file. Each ran
clean under `RIG_SANITIZE=1 rig run` at the small size. Times are the fastest of 5 to 11
interleaved runs at full size (fasta 25,000,000; its 254 MB output; binarytrees 21) on a Mac at
load 4 to 8, so treat them as rough. Changed files are in `reviews/bg2-idiom-probes/{name}/`.
Nothing under `compare/` was edited.

The ports are good Rig already: `Map[?String, Int]` keyed by views with `ensure(...) += 1`, seven
tasks lending `?data`, the fasta ring of `Task[String]?` slots taken with `<ring[slot]` and
waited with `>block`, `par.map(?runs, |+depth, count| ...)`, `s.read[Bytes]` with
`push(v, keep: k)`. The findings are small.

## Ranked

1. **fasta.rig: the section functions take the writer, as the Rust's do, and `repeat` is the
   Rust's `src.repeat(n / len + 1)[..n]`.** `main` loses its `out = String()` dance. Same time,
   19% less memory. (probed)
2. **binarytrees.rig: `item_check` in three lines with `if t.left as l and t.right as r`;
   `Tree()` from field defaults.** (probed)
3. **All 8: header in house style** (what the program is, then `# Ports …` with the authors),
   and the Rust comparisons and "to be replaced once it is built" out of the comments. (probed)
4. **binarytrees-fast.rig: `tree_check` goes; the stretch tree is `run(stretch, 1)`.** (probed)
5. **fasta, binarytrees: `math.min`/`math.max` for the five `a if a > b else b` lines; arrays
   lent whole (`!iub`, `iub`) where `!iub[..]` was written.** (probed)
6. **knucleotide-fast.rig: prime the first `k - 1` bases, then count, as the Rust's `Iter::new`
   does,** which drops the per-base `continue if`. Same time. (probed)
7. **revcomp.rig: `end` in one line. revcomp-fast.rig: `add_reversed(…, start, end)`.** (probed)
8. Not recommended now: **knucleotide.rig's `read_input` as the Rust's two loops over one
   `text.lines` iterator.** Clearer, but the program measured 12 to 15% slower (below).

## fasta.rig

**1. Each section writes itself, and `repeat` repeats the source whole.** (probed: identical,
redirected too; 1.66 s against 1.72 s; peak memory 267 MB against 329 MB)
```
before:                                          after:
sub add_lines(out: !String, bytes: ?String)      sub write_lines(out: !file.File, desc: ?String,
  at = 0                                                         bytes: ?String)!
  while at < bytes.len : at += LINE                lines = String(">", desc, "\n")
    end = at + LINE                                !lines.reserve(bytes.len + bytes.len / LINE + 1)
    end = bytes.len if end > bytes.len             at = 0
    !out.add(bytes[at..end], "\n")                 while at < bytes.len : at += LINE
                                                     !lines.add(bytes[at..math.min(at + LINE,
sub repeat(out: !String, desc, src, n: Int)                     bytes.len)], "\n")
  !out.add(">", desc, "\n")                        (!out).write(lines)!
  res = String()
  !res.reserve(n)                                sub repeat(out: !file.File, desc, src, n: Int)!
  for i in 0..n                                    res = String()
    !res.push(src[i % src.len])                    for 0..n / src.len + 1
  add_lines(!out, res)                               !res.add(src)
                                                   write_lines(!out, desc, res[..n])!
...                                              ...
  stdout = file.create("/dev/stdout")!             stdout = file.create("/dev/stdout")!
  out = String()                                   repeat(!stdout, "ONE Homo sapiens alu", alu,
  repeat(!out, "ONE ...", alu, n * 2)                     n * 2)!
  random(!out, "TWO ...", !iub[..], n * 3, !seed)  random(!stdout, "TWO IUB ambiguity codes",
  (!stdout).write(out)!                                   !iub, n * 3, !seed)!
  out = String()                                   random(!stdout, "THREE Homo sapiens
  random(!out, "THREE ...", !homo_sapiens[..],            frequency", !homo_sapiens, n * 5,
         n * 5, !seed)                                    !seed)!
  (!stdout).write(out)!
```
(Wrapped here to fit; the probe file keeps each call on one line.) Why: the Rust's `repeat` and
`random` each take the writer and write their own header and lines; the port now does too, and
`main` is three calls instead of a buffer written twice and remade. `repeat` is the Rust's
`src.repeat(n / src.len() + 1)[..n]`: whole copies of `src` and a slice, not a `%` per byte.
`math.min` replaces the two-line clamp. The output is one write per section, and the lined text
is reserved up front, which is where the memory went.

**2. `!iub` and `!homo_sapiens` lend the arrays whole.** (probed) `![]Pick` takes an array as
it is; `[..]` adds nothing. The same in fasta-fast: `set_bounds(!iub)` and `random(…, iub, …)`
into `[]Pick`.

**3. Header.** (probed)
```
# The Computer Language Benchmarks Game: fasta, three sections of DNA, one repeated from a fixed
# sequence and two drawn by a linear congruential generator from tables of cumulative
# probabilities, 60 bases to a line. Each section is made whole, then cut into lines.
# Ports benchmarksgame/sources/fasta/fasta.rust-6 (Aok Niman).
```
Why: house style §3. "the plainest Rust" is a comparison with Rust; notes.md says it.

Tried and rejected: `Pick('a', 0.27)` to shorten the tables. Rig sets the fields of a type with
more than one by name ("a type with more than one field sets them by name"), which is right.

## fasta-fast.rig

**4. `count = math.min(BLOCK, left)` and `count = math.min(LINE, left)`.** (probed: identical;
0.68 s both) Why: the Rust writes `min(LINE_LENGTH, n)`; a min reads as one.

**5. Arrays lent whole**, as (2). **6. Header**, naming rust-5 (TeXitoi, Alisdair Owens,
pmarcelll), and `set_bounds`'s comment ends at "summed in F32" without "as the Rust does".
(probed)

The ring is right. Its setup loop (`for 0..IN_FLIGHT` / `!ring.push(none)`) would be
`ring: [IN_FLIGHT]Task[String]? = [IN_FLIGHT of none]`, but that is refused (new finding below).

## revcomp.rig

**7. The end of each sequence in one line**, as revcomp-fast's `blocks` writes it. (probed)
```
before:                                              after:
    next = text.find(input[at + 1..], ">") ?? ...      end = (text.find(input[at + 1..], ">")
    next += at + 1                                            ?? input.len - at - 1) + at + 1
    !tasks.add(reverse_complement(?input[at..next])&)  !tasks.add(reverse_complement(?input[at..end])&)
    at = next                                          at = end
```
(One line in the file.) Why: `end` names the slice's end; one line fewer.

**8. Header**, naming all five rust-3 authors from its source. (probed)

The task per sequence is rust-3's own top level (`rayon::join` of this sequence against reading
the next). Rust-3's halving inside a sequence is not ported, for the routed in-place gap; notes.md
says so. Nothing else to change.

## revcomp-fast.rig

**9. `add_reversed(out, s, start, end)`, walking `at` down.** (probed: identical; 17 ms both
at 25 MB) Why: `p`, `q`, and a local `end = q` become the slice's own words, and `at` is the
cursor. The code is otherwise the same.

**10. Header and `BLOCK_LINES` comment** without the Rust comparisons ("`tbl` on ARM, `pshufb`
on x86; the Rust's vector code is x86 only", "Four times the Rust's 4096"): notes.md has both.
(probed)
```
# Each block is a write of its own, and in a program with tasks a write costs about 20 us.
BLOCK_LINES = 16384
```

## knucleotide.rig

**11. Header**, and `fixed`'s comment made timeless (probed):
```
# `x` with `digits` decimals, rounded to the nearest; within an ulp of a half it may round
# either way.
```
"as Rust's `{:.3}` does" and "A stand-in for the approved `text.format_float`, to be replaced
once it is built" go to notes.md, which already has them. The same in knucleotide-fast.

**12. (Not now) `read_input` as the Rust's two loops.** (probed:
`knucleotide-twoloops.rig`; identical; **1.60 s against 1.40 s at 254 MB**)
```
before:                                       after:
  started = false                               lines = text.lines(input)
  for line in text.lines(input)                 for line in !lines
    if started                                    break if text.contains(line, "THREE")
      for b in line                             for line in !lines
        !data.push(text.to_upper(b))              for b in line
    else                                            !data.push(text.to_upper(b))
      started = text.contains(line, "THREE")
```
Why it reads better: no flag, and "skip to THREE, then take the rest" is the Rust's own shape,
one iterator walked by two loops. Why not now: the whole program ran 12 to 15% slower in four
interleaved sets, though `read_input` alone (a build that only reads and prints the length)
runs the same (0.248 s, the same instruction count). The slowdown is in the counting tasks: 2%
more instructions, and wall time up while CPU time is not. It looks like a layout or inlining
effect, not the form. Worth a look by the speed reviewer; until then the flag stays.

## knucleotide-fast.rig

**13. Prime, then count**, as the Rust's `Iter::new` takes `frame - 1` bases first. (probed:
identical; 0.680 s against 0.685 s, 9 rounds)
```
before:                                          after:
  for b, i in seq                                  for b in seq[..k - 1]
    code = ((code <<% 2) | U64(b)) & mask            code = (code <<% 2) | U64(b)
    continue if i + 1 < k                          for b in seq[k - 1..]
    (!counts).ensure(mix(code), 0) += 1              code = ((code <<% 2) | U64(b)) & mask
                                                     (!counts).ensure(mix(code), 0) += 1
```
Why: the counting loop says only what it does per base, and the warm-up is its own loop. One
line more.

**14. Header; `print_percents` says "a percentage figured in F32"** without "as the Rust has
it"; `fixed` as (11). (probed) The `mix` comment is the routed HashMap gap; left as is.

## binarytrees.rig

**15. `item_check` with both children bound at once, and `Tree()`.** (probed: identical at 10,
18, and 21; 1.23 s against 1.29 s; same memory)
```
before:                                after:
obj Tree                               obj Tree
  left: ^Tree?                           left: ^Tree? = none
  right: ^Tree?                          right: ^Tree? = none

  return Tree(left: none,                return Tree() if depth == 0
              right: none) if depth == 0
                                       fun item_check(t: ?Tree) -> Int
fun item_check(t: ?Tree) -> Int          if t.left as l and t.right as r
  n = 1                                    return 1 + item_check(l) + item_check(r)
  if t.left as l                         1
    n += item_check(l)
  if t.right as r
    n += item_check(r)
  n
```
Why: a node has both children or neither, and `if a as x and b as y` says so; it is the shape
of rust-5's `if let (Some(left), Some(right))`. House style: no constructor arguments where
field defaults suffice.

**16. `max_depth = math.max(n, MIN_DEPTH + 2)`**, and the stretch line under 100 columns by
naming `check` first (the tree is still a temporary, dropped at the statement's end: same peak
memory). **Header** without "the Rust puts them in an arena (typed-arena), which Rig has none
of" (notes.md; routed). (probed)

## binarytrees-fast.rig

**17. `tree_check` goes: the stretch tree is `run(stretch, 1)`.** (probed: identical at 10, 18,
21; 0.247 s against 0.256 s) Why: `run(depth, count)` already is "the checks of `count` trees,
each in a fresh pool"; a second function for one tree is 6 lines that say the same.

**18. `math.min(per, left)`, `math.max(n, MIN_DEPTH + 2)`, the long-lived line under 100
columns, header** without the bumpalo/arena comparison, and `bottom_up_tree`'s comment without
"as the Rust allocates them". (probed)

## New findings

- **`[n of none]` and `List.filled(n, none)` are refused for an optional owner.** fasta-fast's
  ring wants `ring: [IN_FLIGHT]Task[String]? = [IN_FLIGHT of none]`; the checker says "`[n of x]`
  copies its element into every slot, and a `Task[String]?` owns a resource, so it cannot be
  copied". A `none` owns nothing, so each slot could be made `none` anew. Probe:
  `reviews/bg2-idiom-probes/ring-filled-none.rig`. Small; it would also give the ring a fixed
  array instead of a List.
- **A small, unrelated edit moved knucleotide.rig's counting tasks by 12 to 15%** (finding 12).
  Not a language gap; for the speed reviewer, since it means a port's time can swing with code
  that is not on its hot path.
- Confirmed working, worth using elsewhere: `if a as x and b as y`, a `text.lines` iterator
  walked by two `for line in !lines` loops, and `![]T` / `[]T` parameters taking an array bare.
  (`reviews/bg2-idiom-probes/forms-probe.rig`)
