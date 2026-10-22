# Rust's standard library as a model for Rig's

Research note, 2026-09-29. Sources: Rust 1.98.1 std docs installed
locally (`~/.rustup/toolchains/1.98.1-aarch64-apple-darwin/share/doc/rust/html`),
Rig at `5a40305` (WELCOME.md, SPEC.md, SYNTAX.md, docs/ROADMAP.md,
docs/zig-0.16.md, `src/runtime.zig`), and small probe programs run with
`bin/rig run` (kept in `scratchpad/stdlib/probe/`). Every claim below
about what Rig accepts or rejects today comes from one of those probes
or from SPEC.

Method counts are inherent methods on the type's own page, including
unstable ones, excluding trait impls and deref targets. They measure
surface size, not quality.

## Notation used in this note

- `?self`, `!self`, `<self` are the receiver modes. A parameter `x: T`
  of an owning type takes ownership; the caller writes `<x` (move) or
  `+x` (clone). Rig has no `<T` type form, so the prompt's
  `sub push(!self, x: <T)` is written `sub push(!self, x: T)` and the
  `<` shows up at the call.
- **`?T?` vs `(?T)?`.** SYNTAX §7 says a borrow applies to the whole type
  after it, so `?T?` is *a borrow of an optional*. What `get` returns
  is *an optional borrow*, which is written `(?T)?`. That form already
  works (`test/behavior/emit/optional_borrow_from_branch.rig` has
  `fun get(?self, k: Int) -> (?T)?`). This note writes `(?T)?` and
  `(!T)?`. If `?T?` reads better in return position, that would be a
  deliberate syntax change.
- Gap labels: **[R]** writable in Rig today; **[B]** needs a compiler
  builtin or runtime support (Zig in `src/runtime.zig` plus sema
  knowledge, as `Vec` has now); **[L]** needs a language change. Gap
  IDs (G1 to G19) are defined in §4.

---

## 1. Module-by-module map of Rust std

### At a glance

| Module / type | Tier | Size (inherent methods) | Rig today |
|---|---|---|---|
| primitives: integers, floats, `bool` | 1 | `i64` 151, `u8` 174, `f64` 79 | numbers, `.min`/`.max`, conversions, `+% -% *%` |
| `str` / `String` | 1 | `str` 91, `String` 48 | `String` view: `len`, index, `get`, slices, `==`, `<`, `for` bytes |
| slices `[T]` / arrays | 1 | slice 171 | `[]T`, `![]T`, `copy`, `fill`, `swap`, `read`/`write` |
| `Vec` | 1 | 69 (+171 through deref) | `Vec`: `push`, `pop`, `get`, `clear`, `len`, index (Copy only) |
| `Option` / `Result` | 1 | 52 / 38 | `T?`, `T!`, `??`, `?`, `!`, `catch`, `as` |
| `collections::HashMap` / `HashSet` | 1 | 38 / 37 | none |
| `fmt` (`format!`, `Display`, `Debug`) | 1 | macros and traits | `print` only |
| `io` (stdin/stdout, `Read`, `Write`, `BufRead`) | 1 | traits | `print` only |
| `fs` + `path` | 1 | `File` 19, `Path` 44, `PathBuf` 24 | none |
| `env` (args, vars) | 1 | ~20 fns | none |
| `process` (`exit`, `Command`) | 1 (`exit`), 2 (`Command`) | | none |
| `iter` | 1 | `Iterator` 76 | `for` over builtins; `while !it.next() as x` |
| `cmp` (`Ord`, `min`, `max`, `Reverse`) | 1 | traits | `<` on numbers, `String`, `[]U8`; `==` structural |
| `hash` | 2 (users), 1 (for maps) | traits | none |
| `mem` (`replace`, `swap`, `take`, `drop`, `size_of`) | 1 | ~20 fns | `replace`, `swap`, `-x`, `@sizeOf`, `<s.f` (take) |
| `time` | 2 | `Instant` 7, `Duration` 42 | none |
| `num` (parsing, `NonZero`, `Wrapping`) | 2 | | none |
| `char` / unicode | 2 | `char` 49 | none (no char type) |
| `ascii` | 2 | on `u8`/`str` | none |
| `error` (`Error` trait, `Box<dyn Error>`) | 2 | trait | `error` sets, any-error `T!` |
| `convert` (`From`, `Into`, `AsRef`, `TryFrom`) | 1 (pervasive) | traits | conversions by type name (`U8(x)`) |
| `borrow` (`Cow`, `Borrow`, `ToOwned`) | 2 | traits | none |
| `rc`, `cell`, `boxed` | 1 | | `*T`, `~T`, `Cell`, `Box` in the language |
| `thread`, `sync` (`Arc`, `Mutex`, `mpsc`) | 2 | | no concurrency (roadmap) |
| `ffi` (`CString`, `OsString`) | 3 | | `extern` with numbers only |
| `net` | 3 | | none |
| `random` | nightly only | `random`, `Rng` | none |
| `collections::{BTreeMap, VecDeque, BinaryHeap, LinkedList}` | 2 / 3 | | none |

### Primitives: integers, floats, bool

- **Tier 1.** Every program uses them. The method surface is huge
  (`i64` 151, `u8` 174) because each operation family is multiplied by
  overflow policy (`checked_`, `wrapping_`, `saturating_`,
  `overflowing_`, `strict_`, `unchecked_`) and by width.
- **Ownership:** none, since these are `Copy`.
- **Traits:** `Add`/`Ord`/`Hash`/`Display`/`FromStr` make numbers usable
  generically, and `From<u8> for u32` gives lossless widening.
- **Rig without traits:** arithmetic, `==` and `<` already work on a
  generic `T` and are checked per instance (SPEC §3 "Generic bodies").
  Rig's operators already pick an overflow policy (`+` checked, `+%`
  wrapping), so a stdlib needs only a small checked family returning
  `T?` for code that must not panic, not Rust's six-way family.
  Conversions are the type name (`U8(x)`, checked).

### `str` and `String`

- **Tier 1.** The single most-used API after `Vec`.
- **Ownership:**
  - This is the canonical view/owner split. `&str` borrows and `String`
    owns; `String: Deref<Target = str>`, so every read method is
    written once on `str`.
  - Functions take `&str` and return `String` only when they allocate.
  - `push_str(&mut self, &str)` appends. `String + &str` consumes the
    left operand and reuses its buffer, which moves a value inside an
    operator.
  - `into_bytes(self)` and `String::from_utf8(Vec<u8>)` move the
    buffer without copying. `drain(range)` removes a range and yields
    it.
- **Panicking vs fallible:**
  - `&s[a..b]` panics off a char boundary, and `s.get(a..b)` returns
    `Option`.
  - `from_utf8` returns `Result`; `from_utf8_lossy` returns
    `Cow<str>`.
- **Traits:** `Pattern` (so `find` accepts `&str`, `char`, a closure,
  or `&[char]`), `FromStr` for `parse::<T>()`, `Display`/`ToString`,
  `Borrow<str>` (so a `HashMap<String, V>` is looked up with `&str`),
  `AsRef<str>`, `AsRef<Path>`, `AsRef<OsStr>`, and `AsRef<[u8]>`.
- **Rig without traits:**
  - Settled: `String` stays the view and `Text` is the owner.
  - Instead of `Pattern`, take `String` patterns and add a separate
    byte variant where needed (`find_byte`).
  - `parse` is per type: `Int.parse(s)` and `Float.parse(s)`, or one
    `parse[T](s)` builtin checked per instance, with numbers only.

### Slices and arrays

- **Tier 1.** Slices carry most of the algorithms: `sort`, `sort_by`,
  `sort_by_key`, `sort_unstable`, `binary_search`, `contains`,
  `iter`, `chunks`, `windows`, `split`, `reverse`, `rotate_left`,
  `fill`, `copy_from_slice`, `swap`, `concat`, and `join`.
- **Ownership:** `&[T]` vs `&mut [T]` is the whole story, but the
  language can't be generic over mutability, so the API doubles. The
  slice page has **42 `_mut` twins** (`get_mut`, `first_mut`,
  `iter_mut`, `split_at_mut`, `chunks_mut`, …) and `Vec` has 44
  counting deref. `split_at_mut` exists because the borrow checker
  can't see two disjoint borrows of one slice.
- **Traits:**
  - `sort` needs `Ord`; `f64` is only `PartialOrd`, so `v.sort()` on
    floats does not compile. Everyone writes
    `sort_by(|a, b| a.partial_cmp(b).unwrap())`, or `total_cmp` since
    1.62.
  - `contains` needs `PartialEq`, `concat`/`join` need `Borrow`, and
    `to_vec` needs `Clone`.
- **Rig without traits:**
  - Rig already lends slices by sigil (`?a[..]`, `!a[..]`) and walks
    them by sigil (`for x in ?v` / `!v` / `<v`). The receiver sigil is
    at the call site, so the mode can pick the behavior and one name
    can serve both.
  - `sort` on a generic `T` uses `<`, which Rig checks per instance.
    `sort_by` takes `?fun(?T, ?T) -> Bool`, and `examples/sort.rig`
    already does exactly this.
  - Floats should sort by total order (NaN last) rather than being
    rejected.

### `Vec`

- **Tier 1.**
- **Ownership:** the reference design for an owning container.
  - `push(&mut self, T)` takes ownership, and `pop(&mut self) ->
    Option<T>` gives it back.
  - `remove(i) -> T` and `swap_remove(i) -> T` hand elements out.
  - `truncate` and `clear` drop elements.
  - `drain(range)` is a by-value iterator that removes on the fly and
    fixes up the tail when it is dropped. That needs a guard type, and
    `mem::forget` of the guard is a known soundness hazard, handled by
    leak amplification.
  - `retain(|&T| -> bool)` drops the rejected elements;
    `extend(IntoIterator)` moves in and `extend_from_slice(&[T])`
    clones in. `split_off`, `append(&mut Vec)` (moves all out of the
    other), and `dedup` complete the set.
  - Indexing panics and `get` returns `Option<&T>`.
- **Traits:** `Clone` (for `vec![x; n]`, `resize`, and
  `extend_from_slice`), `PartialEq` (for `dedup` and `contains`),
  `IntoIterator`, `FromIterator` (`collect`), and `Extend`.
- **Rig without traits:** most of this is ownership-only and needs no
  trait. Rig can clone per instance with `+x` and requires plain data
  where it copies, as `copy` and `fill` already do. Replace `drain` by
  a method that returns a new `Vec[T]` of the removed range: one
  allocation, visible in the result type, and no guard object.

### `Option` / `Result`

- **Tier 1.**
- **Ownership:** `as_ref`/`as_mut` turn `&Option<T>` into
  `Option<&T>`, and `take(&mut self)` moves out leaving `None`.
  `replace`, `insert`, and `get_or_insert_with` round out the in-place
  forms, and `unwrap`/`expect` consume.
- **Combinators:** 52 methods on `Option` and 38 on `Result`,
  including `map`, `and_then`, `or_else`, `ok_or`, `filter`, `zip`,
  `xor`, `unwrap_or_default`, `is_some_and`, `is_none_or`,
  `map_or_else`, `inspect`, `copied`, `cloned`, and `transpose`.
  Several exist only to route around the lack of control flow inside
  closures.
- **Rig:** the language already covers the everyday core with
  operators and statements.

  | Rust | Rig |
  |---|---|
  | `unwrap_or` | `??` |
  | `?` on an `Option` | `?` |
  | `?` on a `Result` | `!` |
  | `unwrap_or_else(\|\| return)` | `?? return` |
  | `if let` | `if o as x` |
  | `as_ref`/`as_mut` | `if ?o as x` / `if !o as x` |
  | `take` | `<s.f` |
  | `unwrap_or` on a `Result` | `catch` |

  Rig should **not** add the combinator set. `unwrap`/`expect` have no
  place in tier 1; `x ?? panic("...")` would be the explicit form if a
  `panic` builtin is added.

### `collections::HashMap` / `HashSet` (and BTree, VecDeque, BinaryHeap)

- **Tier 1** for `HashMap`/`HashSet`; tier 2 for `BTreeMap`,
  `VecDeque`, and `BinaryHeap`; tier 3 for `LinkedList`.
- **Ownership:** Rust's best-designed API.
  - `insert(K, V) -> Option<V>` moves both in and hands back the value
    it replaces.
  - `get<Q>(&Q) -> Option<&V>` borrows. Through
    `K: Borrow<Q>, Q: Hash + Eq`, a `HashMap<String, V>` is looked up
    by `&str` without allocating.
  - `get_mut` lends for writing; `remove(&Q) -> Option<V>` and
    `remove_entry` hand ownership back.
  - **The entry API**, `map.entry(k).or_insert(0) += 1` or
    `.or_insert_with(Vec::new).push(x)`, does one hash lookup, moves
    the key in only when it is absent, and returns `&mut V` tied to
    the map borrow. It exists because
    `if !m.contains_key(k) { m.insert(k, v) }; m.get_mut(k)` hashes
    three times and fights the borrow checker. The `Entry` enum with
    `Occupied`/`Vacant` is the general form, used rarely.
  - `iter`/`iter_mut`/`into_iter`/`keys`/`values`/`values_mut`/`drain`/`retain`
    repeat the three-mode split.
- **Traits:** `Hash + Eq` on keys, with a `BuildHasher` type parameter
  (default `RandomState`, SipHash-1-3 with a random seed for HashDoS
  resistance). The price is that iteration order is random per
  process, so snapshot tests and printed output are nondeterministic.
  `BTreeMap` needs `Ord`.
- **Rig without traits:**
  - Rig's `==` is already structural and checked per instance, and it
    rejects handles ("could compare by identity or by content").
  - A structural `hash(x)` builtin, specified like `==` (numbers,
    `Bool`, `String`/`Text` by content, plain-data structs, enums, and
    optionals), would make `Map[K, V]` need no user method at all.
    That is exactly Zig's `AutoHashMap` / `StringHashMap`.
  - A per-instance convention (`fun hash(?self) -> U64`,
    `fun eq(?self, o: ?Self) -> Bool`) is the tier-2 escape hatch once
    generic method calls exist (G1).

### `fmt`

- **Tier 1:** `println!`, `format!`, `write!`, `Display`, and
  `Debug`.
- **Mechanism:**
  - Format strings are parsed by compiler-built-in macros
    (`format_args!`) into `fmt::Arguments`, and are type-checked at
    compile time. Implicit captures (`"{x}"`) came in 2021.
  - `Display` is the user-facing form, written by hand. `Debug`
    (`{:?}`) is the developer form, derived.
  - The spec mini-language covers width, fill, alignment, precision,
    sign, `#` alternate, radix (`x`, `b`, `o`), and exponent (`e`).
- **Ownership:** formatting borrows everything (`&T`). `format!`
  allocates a `String`; `write!` into a `&mut String` or `impl Write`
  reuses a buffer.
- **Traits:** `Display`, `Debug`, `LowerHex`, and so on, each
  `fn fmt(&self, f: &mut Formatter) -> fmt::Result`. `ToString` is
  blanket-implemented from `Display`.
- **Rig without traits or macros:**
  - `print` is already a compiler-known variadic whose rendering is
    Debug-like and derived for every type. The runtime has the Zig-side
    hook `__rig_print(self, w)`.
  - The Rig-side equivalent of `Display` is a convention method,
    `sub fmt(?self, out: !Text)`. `print` and `Text.add` call it when
    an instance's type declares it, checked per instance like `==`.
  - Formatting options become small plain-data wrapper values
    (`fmt.hex(n)`, `fmt.pad(x, 8)`, `fmt.fixed(f, 2)`), which print
    through the same hook. Rig needs no format-string parser: a
    variadic `!t.add("x = ", x, "\n")` is the whole `format!`.

### `io`

- **Tier 1:** stdin, stdout, stderr, `read_line`, `lines`, `Write`,
  and buffering.
- **Ownership:**
  - `read_line(&mut self, buf: &mut String) -> io::Result<usize>`
    appends into a caller-owned buffer, which is good: there is no
    allocation per line when reused. `lines()` allocates a `String`
    per line for convenience.
  - `Read::read(&mut self, &mut [u8]) -> Result<usize>` fills a
    caller's slice.
  - `BufReader`/`BufWriter` own an inner reader or writer and give it
    back with `into_inner`.
  - `stdout().lock()` returns a guard.
- **Traits:** `Read`, `Write`, `BufRead`, and `Seek`. Every I/O
  function is generic over `R: Read`, which is the trait system's
  strongest argument.
- **Warts:**
  - `print!` panics on a closed stdout (EPIPE), so `prog | head`
    crashes.
  - `File` is unbuffered by default, and forgetting `BufWriter` is the
    classic Rust performance bug.
  - `io::Error` is one opaque type with `ErrorKind`, which works well
    in practice.
- **Rig:** use concrete types (`File`, `stdin`) rather than a `Read`
  abstraction. Generic "any reader" code waits for G1 and the
  convention `fun read(!self, buf: ![]U8) -> Int!`. Zig 0.16 routes all
  I/O through an explicit `std.Io` value (docs/zig-0.16.md §3); Rig
  keeps it implicit, as it does the allocator, so the runtime must
  hold the process's `Io`.

### `fs` and `path`

- **Tier 1:** `fs::read_to_string`, `fs::write`, `File::open` and
  `create`, `read_dir`, `create_dir_all`, `remove_file`, `metadata`,
  and `exists`. `Path::join`, `extension`, `file_name`, and `parent`.
- **Ownership:**
  - `fs::write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>)`
    borrows both.
  - `read_to_string` returns an owned `String`.
  - `File` closes in `Drop`, so close errors are silently lost;
    `sync_all` is the workaround.
  - `Path` is a view and `PathBuf` the owner, with a separate
    `OsStr`/`OsString` beneath them, because paths aren't guaranteed
    UTF-8. Hence the four-way conversion dance (`to_str() ->
    Option<&str>`, `to_string_lossy() -> Cow<str>`, `display()`).
- **Traits:** `AsRef<Path>`, so any string-ish argument works.
  `read_dir` yields `io::Result<DirEntry>`.
- **Rig:**
  - Paths are Strings: bytes, as in Zig, Go, and C. There are no
    `Path`/`PathBuf`/`OsString` types, and path helpers are functions
    returning views (`path.base(p)`, `path.ext(p)`).
  - Only `join` allocates (a `Text`).
  - `File` has `drop` close it, plus `<f.close()!` to observe errors.

### `env` and `process`

- **Tier 1:** `env::args`, `env::var`, `process::exit`, and
  `fn main() -> ExitCode`. **Tier 2:** `process::Command` (a builder
  with `arg`, `env`, `stdin`, `output()`, `status()`, and `spawn()`).
- **Ownership:**
  - `env::args()` yields owned `String`s and panics on non-UTF-8;
    `args_os()` yields `OsString`s.
  - `env::var` returns `Result<String, VarError>`.
  - `env::set_var` became `unsafe` in the 2024 edition, because
    mutating the environment races with any reader, including libc
    inside other threads. This is a lesson in removing an API.
  - `process::exit` runs no destructors.
- **Rig:**
  - Arguments and environment are captured once at startup in the
    runtime. Zig 0.16 hands them to `main(init: std.process.Init)`,
    so the emitted `main` has to take them (G14).
  - They can be given out as `String` views valid for the whole
    program, exactly like literals. Nothing borrows, nothing
    allocates, and no `set_env` exists to invalidate them.
  - Exit codes come from `fun main -> Int`, after drops, rather than
    from `exit`, which would skip drops and the Debug leak check.

### `time`

- **Tier 2** (tier 1 for benchmarks, timeouts, and games).
- **Design:** `Instant` is monotonic and opaque, and `SystemTime` is
  wall-clock. `Duration` is `(u64 secs, u32 nanos)` with `+`, `-`, and
  `*` via operator traits, `checked_*` variants, and `as_secs_f64`.
  `thread::sleep` takes a `Duration`. Calendar and date formatting are
  deliberately left to crates (`chrono`, `time`, `jiff`).
- **Ownership:** all `Copy`.
- **Traits:** `Add`/`Sub` for arithmetic ergonomics.
- **Rig:** there is no operator overloading, so follow Go:
  `Duration` is an `Int` of nanoseconds (i64 covers ±292 years), so
  `+`, `-`, `*`, `<`, and `print` all just work, with constants
  `time.SECOND`, `time.MS`, and so on. `Instant` is a plain-data
  struct.

### `thread` and `sync`

- **Tier 2.** `spawn` requires `F: Send + 'static`; `scope` gives
  scoped threads; `Arc`, `Mutex` (a guard lends `&mut T`), `RwLock`,
  `mpsc`, atomics, `OnceLock`, and `LazyLock`.
- **Ownership:** `Send` and `Sync` are auto traits. `Mutex<T>` owning
  its data, with access only through a guard, is Rust's great idea
  here.
- **Rig:** out of scope until the roadmap's structured concurrency and
  thread-safe handles land. When they do, copy "the lock owns the data
  and lends it for a scope": a `lock` that lends `!T` to a block.

### `iter`

- **Tier 1.** `Iterator` has one required method (`next`) and 76
  provided ones: `map`, `filter`, `enumerate`, `zip`, `chain`, `rev`,
  `take`, `skip`, `fold`, `sum`, `collect`, `any`, `all`, `find`,
  `position`, `min_by_key`, `flat_map`, `peekable`, `step_by`,
  `windows`, and more. They are lazy, zero-cost after inlining, and
  monomorphized.
- **Ownership:** `iter()` yields `&T`, `iter_mut()` yields `&mut T`,
  and `into_iter()` yields `T`. `for` desugars to `IntoIterator`. The
  item type cannot borrow from the iterator itself ("lending
  iterators" are still not expressible in std), so `lines()` must
  allocate each line.
- **Traits:** everything: `Iterator`, `IntoIterator`, `FromIterator`,
  `Extend`, `DoubleEndedIterator`, `ExactSizeIterator`, `Sum`, and
  `Product`.
- **Rig:**
  - Settled: `while !it.next() as x`, and `for` never calls user
    methods.
  - Under Rig's rule that a borrow a call returns borrows from its
    arguments, a `next(!self)` returning a view borrows the iterator.
    Rig iterators are therefore naturally *lending*: a `lines`
    iterator can hand out a `String` view of its own reused buffer,
    which Rust's `Iterator` cannot.
  - Adapters wait for traits. Eager generic functions over slices
    returning a `Vec` (`map`, `filter`, `sum`) cover the common cases,
    and `examples/sort.rig` already defines `map`.

### `cmp` and `hash`

- **Tier 1** through their use in sorting, maps, `min`, and `max`.
  `PartialEq`/`Eq`/`PartialOrd`/`Ord` and `Hash` are usually derived.
  `Ordering` is an enum; `Reverse<T>` is a wrapper; `min_by_key` and
  `max_by` take closures.
- **Rig:**
  - `==` is structural everywhere and `<` covers numbers, `String`,
    and `[]U8`.
  - Ordering beyond that comes by closure (`less: ?fun(?T, ?T) ->
    Bool`), and later by the convention `fun less(?self, o: ?Self) ->
    Bool` or `fun cmp(?self, o: ?Self) -> Order` (G1).
  - A structural `hash` builtin (G18) covers maps. Rust's `Eq` exists
    to keep `f64` out of hash keys, so Rig should reject `Float` (and
    structs holding one) as `Map` keys per instance, the same way it
    rejects handles in `==`.

### `mem`

- **Tier 1:** `replace`, `swap`, `take`, `drop`, and `size_of`.
  **Tier 3:** `forget`, `transmute`, and `MaybeUninit`.
- **Ownership:** `replace`, `swap`, and `take` are how you move out of
  a `&mut` place, the key trick for writing data structures in safe
  Rust. `take` needs `Default`.
- **Rig:** already has `replace(!place, v)`, `swap(!a, !b)`, `-x`,
  `@sizeOf`, and `<s.f` for optional fields (which is
  `Option::take`). `take` without `Default` is `replace(!x, empty)`.
  Nothing to add in tier 1.

### `num`

- **Tier 2.**
  - `str::parse::<i64>()` via `FromStr`, and `i64::from_str_radix`.
  - `ParseIntError` with `kind()` (empty, invalid digit, overflow).
  - `NonZero<T>` for niche optimization, and `Wrapping<T>`.
  - `pow`, `isqrt`, `abs_diff`, `rem_euclid`, `div_euclid`,
    `leading_zeros`, `count_ones`, and `to_le_bytes`/`from_le_bytes`.
- **Rig:**
  - `parse` (tier 1).
  - Bit operations as `math` functions or safe builtins
    (`@popCount`, `@clz`, `@ctz` are pure).
  - Bytes already have `read[T, e]` and `write[T, e]`, which replace
    `to_le_bytes`/`from_le_bytes`.
  - `rem_euclid` matters because `%` truncates; offer `math.mod(a, b)`
    with a floor result.

### `char`, unicode, and `ascii`

- **Tier 2.** `char` is a Unicode scalar value (4 bytes). `str::chars()`
  decodes UTF-8, and `char::is_alphabetic`, `to_uppercase` (which
  returns an iterator, since one char can map to several),
  `char_indices`, and `encode_utf8` go with it. The `ascii` family on
  `u8`/`str` has `is_ascii_digit`, `to_ascii_lowercase`, and
  `eq_ignore_ascii_case`.
- **Rig:**
  - No `char` type is needed in tier 1. A `for b in s` loop gives
    bytes; a `utf8` iterator giving `U32` code points is tier 2.
  - ASCII predicates on `U8` are tier 1, cheap, and writable in Rig
    today as functions.
  - Unicode case mapping and classification need tables: tier 3, or a
    library.

### `error`

- **Tier 2.**
  - `std::error::Error` (`Display + Debug + source()`), plus
    `Box<dyn Error>` as the "any error" type and `?` converting
    through `From`.
  - Ecosystem crates (`anyhow`, `thiserror`) exist because std's story
    is incomplete.
  - Errors carry payloads (`io::Error` holds an OS code and a message;
    `ParseIntError` a kind).
- **Rig:** errors are names, unified by name like Zig error sets, and
  any fallible function may fail with any error (SPEC §13).
  - This is simpler than Rust's and suits a stdlib: `fs` fails with
    members of one public `error IoError` set.
  - What Rig loses is payloads, such as *which* file was not found.
    Program-level context has to be added by the caller. Rust's lesson
    is that a stdlib error should carry the OS code but not the path
    (`io::Error` doesn't carry the path either, which is a common
    complaint). Rig can match Rust here by exposing
    `os.last_error_code()` for diagnostics.

### `convert` and `borrow`

- **Tier 1 by pervasiveness:** `From`/`Into`/`TryFrom`/`AsRef`, and
  `Cow`, `Borrow`, `ToOwned`.
- **What they do:**
  - `AsRef<Path>` and `Into<String>` make signatures polymorphic over
    owned and borrowed arguments.
  - `Borrow` makes map lookup by a view possible.
  - `Cow` avoids allocating when no change is needed
    (`from_utf8_lossy`).
- **Rig:** replace with fewer types rather than conversion traits.
  - With one view/owner pair (`String`/`Text`, `[]T`/`Vec[T]`), APIs
    take the view and the caller lends (`?t[..]`, `?v[..]`).
  - Map lookup by view is a per-instance rule: `get` accepts any `Q`
    for which `K == Q` is defined and `hash(Q) == hash(K)`, which the
    compiler guarantees for `Text`/`String`.
  - No `Cow` in tier 1.

### `rc`, `cell`, and `boxed`

- These are in Rig's language: `*T`, `~T`, `Cell[T]`, and `Box[T]`.
- Rig's `Cell` never lends its contents; it answers `get`, `set`,
  `replace`, and a few Vec members. That avoids `RefCell`'s runtime
  borrow panics (`BorrowMutError`), a clear improvement on Rust.

### `ffi`

- **Tier 3** for most programs. `CString` (owned, NUL-terminated),
  `CStr`, and `OsString`/`OsStr`.
- **Rig (settled):** `[]U8` goes to C as pointer plus length, and a
  NUL-terminated copy is explicit (`t.cstr() -> Vec[U8]`).

### `random`

- Nightly only in Rust (`std::random::random`, `Rng`, `SystemRng`);
  every stable program uses the `rand` crate. Leaving it out of std
  sent a large ecosystem into dependency churn.
- **Rig:** include a small seeded PRNG and an OS-entropy function, as
  Zig (`std.Random`) and Go (`math/rand`) do.

---

## 2. Lessons

### What Rust std got right, and Rig should copy

1. **One view/owner pair per kind of data, with the algorithms on the
   view.** `str`/`String`, `[T]`/`Vec<T>`: read methods are written
   once on the view, and owners reach them by deref. Rig already has
   `String`/`Text` and `[]T`/`Vec[T]`. Put every read algorithm on
   `String` and on `[]T`/`![]T`. `Vec` and `Text` then get them by
   lending (`?v[..]`, `?t[..]`), and arrays get them too.
2. **Ownership in the signature is the documentation.** `push(T)`
   takes, `pop() -> Option<T>` gives back, `get(&self) -> Option<&T>`
   lends, `remove(i) -> T` hands out, and `insert(k, v) -> Option<V>`
   returns what it displaced. Rig's sigils put the same facts at the
   call site (`!v.push(<x)`), which is better still. Every stdlib
   method should have a receiver mode and parameter types that alone
   say who owns what afterwards.
3. **The entry API: one lookup, and the key moves in only if needed.**
   The general `Entry` enum is overkill. What people use is
   `entry(k).or_insert(v)` returning `&mut V`, and Rig should ship
   that as `!m.slot(<k, v) -> !V`.
4. **Move-out-of-a-place primitives.** `mem::replace`, `swap`, `take`,
   and `Option::take`. Rig has them all.
5. **`read_line(&mut buf)`: the caller owns the buffer.** Reuse
   without allocation is the systems-language default, and the
   convenience form (`lines`) is layered on top. Rig's lending
   iterators can make even the convenience form allocation-free.
6. **Checked by default, panics reserved for bugs.** Indexing panics
   and `get` returns `Option`; integer overflow panics in debug; I/O,
   parsing, and environment lookups return `Result`. Rig follows this
   (`v[i]` panics, `v.get(i)` is `T?`). The rule to write down: *a
   precondition the caller controls may panic; anything that depends
   on the outside world returns `T!` or `T?`*.
7. **`Instant` vs `SystemTime`.** Two clocks with two types, so
   monotonic durations can't be mixed with wall time by accident.
8. **`Mutex<T>` owns its data** (for later): the lock and the thing it
   protects are one value.
9. **`io::Error` as one error type with a kind.** A stdlib should fail
   with one small, stable error set per domain, not a type per
   function.
10. **Removing APIs that can't be made safe.** `env::set_var` became
    `unsafe`. Rig should simply not have `set_env` in tier 1.

### What Rig should avoid

1. **API bloat from multiplying policies.** `i64` has 151 methods,
   `u8` 174, slice 171, `Vec` 69 (+171), `str` 91, `Option` 52. Much
   of it is the cross product of an operation with overflow policy,
   mutability, direction (`r`-prefixed), and exactness (`_exact`,
   `_checked`, `_unchecked`).
   - Rig's operators already encode overflow policy.
   - Sigils encode mutability, so **there should be no `_mut`
     twins**. Rust has 42 on slices alone because `&mut` isn't visible
     at the call site; in Rig it is, so `!v.get(i)` can mean the
     writable form of `v.get(i)` (G9).
   - Every added tier-1 method has to earn its place, and a
     `split_at`-style pair can wait for demand.
2. **The combinator explosion.** `Option`/`Result`/`Iterator` have
   ~165 methods between them, many of which re-encode control flow
   (`map_or_else`, `unwrap_or_default`, `is_some_and`, `ok_or_else`,
   `and_then`). Rig's `??`, `?`, `!`, `catch`, `as`, `?? return`,
   `catch break`, and the jump-taking handlers already say these
   things in the language. **Do not add `map`/`and_then`/`unwrap` to
   optionals.** Iterator adapters wait for traits, and even then should
   stay small.
3. **String-type proliferation.** Rust has `str`, `String`, `OsStr`,
   `OsString`, `Path`, `PathBuf`, `CStr`, `CString`, `Cow<str>`,
   `Box<str>`, `Rc<str>`, and `Arc<str>`, plus `[u8]` and `Vec<u8>`.
   Rig should have exactly `String` (view) and `Text` (owner), plus
   `[]U8`/`Vec[U8]` for bytes.
   - Paths, arguments, and environment values are `String`.
   - Define `String` as **bytes that are conventionally UTF-8**, as Go
     does. It is not validated on slicing, so it can't panic at a
     "char boundary" the way Rust's `&s[a..b]` does, and it needs no
     `OsString` for non-UTF-8 file names.
   - Validation happens only where it matters: `Text.from_bytes`,
     `s.is_utf8()`, and the `utf8` decoder.
   - This is a decision the user should make explicitly. SPEC §2 today
     says "immutable UTF-8 bytes" without saying whether it is checked.
4. **Panicking convenience APIs.** Avoid `unwrap`, `expect`, `print!`
   panicking on EPIPE, `env::args()` panicking on non-UTF-8,
   `Vec::remove` panicking (acceptable, since the index is a caller
   precondition), `RefCell` panics, `str` char-boundary panics, and
   `Duration` arithmetic panics. For Rig:
   - `print` on a closed pipe should end the program quietly (exit
     status 141 / SIGPIPE convention), not panic.
   - `os.args` should never panic.
   - Out-of-range integer conversions already panic, and that is fine.
5. **Hidden allocation in convenience methods.** `lines()`,
   `to_string()`, `collect()`, `format!`, and `to_uppercase()` all
   allocate. Rig's rule: a function allocates only when its result
   type is an owner (`Text`, `Vec`, `Map`, `Box`), or when it appends
   into a `!Text`/`!Vec` the caller passed. No internal scratch
   allocation. In particular, `sort` should be stable *and* in place
   (Zig's `std.sort.block` is), unlike Rust's stable `sort`, which
   allocates a buffer.
6. **Randomized hash iteration order.** Rig's rule 1 is that a
   feature exists when a program prints the right thing. Every doc
   example with a map would be flaky under Rust's `RandomState`. Make
   the tier-1 `Map` **insertion-ordered** (Zig's `ArrayHashMap`,
   Python's `dict`): deterministic output, `keys()`/`values()` as
   contiguous slices, and faster iteration. Offer seeded hashing later
   if HashDoS matters.
7. **Not being able to sort floats.** Rust's `f64: !Ord` makes
   `sort()` on floats a compile error. Rig should sort `Float` by IEEE
   total order (`-NaN < -inf < … < inf < NaN`) and say so.
8. **Leaving randomness and time formatting to crates.** Randomness
   belongs in std. Date formatting can stay out.
9. **Close errors lost in `Drop`.** Give `File` both a `drop` (close,
   ignoring errors) and a consuming `<f.close()!` that reports them.

---

## 3. Proposed tier-1 surface for Rig

Twelve items: prelude types (`String` methods, `Text`, `Vec` and slice
additions, `Map`, `Set`) and seven modules (`fmt`, `io`, `fs` with
`path`, `os`, `math`, `time`, `random`). The signatures are in Rig
syntax.

- Comments name the ownership effect.
- `→ owner` marks a function that allocates, visible because its
  result is an owning type.
- `[R]`, `[B]`, and `[L]` mark what implementing each needs (§4).

### 3.1 `String` (built-in view) — prelude

`String` is Copy and holds no ownership, so every method is `?self`.
A returned `String` is a view of the same bytes. Once G6 lands, it
borrows whatever `self` borrows; for a literal it borrows nothing.

```rig
# existing: s.len, s[i], s.get(i) -> U8?, s[a..b], ==, <, for b in s
fun find(?self, pat: String) -> Int?            # byte offset of the first match
fun rfind(?self, pat: String) -> Int?
fun find_byte(?self, b: U8) -> Int?
fun contains(?self, pat: String) -> Bool
fun starts_with(?self, pat: String) -> Bool
fun ends_with(?self, pat: String) -> Bool
fun count(?self, pat: String) -> Int
fun trim(?self) -> String                       # view; ASCII whitespace
fun trim_start(?self) -> String
fun trim_end(?self) -> String
fun strip_prefix(?self, pat: String) -> String? # view of the rest, or none
fun strip_suffix(?self, pat: String) -> String?
fun cut(?self, sep: String) -> Cut?             # Cut(head: String, tail: String): split_once / Go's Cut
fun split(?self, sep: String) -> Split          # lending iterator: while !it.next() as part
fun lines(?self) -> Lines                       # strips "\n" and "\r\n"
fun words(?self) -> Words                       # split on ASCII whitespace
fun eq_ignore_case(?self, o: String) -> Bool    # ASCII
fun is_utf8(?self) -> Bool
fun bytes(?self) -> []U8                        # the same bytes as a []U8 view

# parsing: associated functions of the number types
Int.parse(s: String) -> Int!                    # error Parse: empty, invalid, overflow
Int.parse_radix(s: String, radix: Int) -> Int!
Float.parse(s: String) -> Float!
# (every integer type: U8.parse, I32.parse, ...)

# ASCII byte helpers (functions on U8 in module `ascii`, or methods on U8)
fun is_digit(b: U8) -> Bool
fun is_alpha(b: U8) -> Bool
fun is_space(b: U8) -> Bool
fun is_alnum(b: U8) -> Bool
fun to_lower(b: U8) -> U8
fun to_upper(b: U8) -> U8
```

`Cut` is a plain struct because Rig has no tuples; `Split`, `Lines`,
and `Words` are plain structs holding a `String` and an offset (probe
`i2.rig` runs such a `Words` today). Case-changing a whole string
allocates, so it lives on `Text`.

### 3.2 `Text` (owned, growable text) — prelude

```rig
Text()                                      # empty; no allocation until the first add
Text(capacity: n)                           # → owner
Text.of(s: String) -> Text                  # copy a view → owner   (Rust: String::from / to_owned)
Text.from_bytes(bytes: Vec[U8]) -> Text!    # takes the buffer (<v), validates UTF-8; fails .invalid_utf8
t.len                                       # bytes; read-only field
t.capacity                                  # read-only field
?t[..], ?t[a..b]                            # lend as a String view; t can't be written while it lives
t == s                                      # compares with a String or Text by content

sub add(!self, a, b, ...)                   # variadic: each value's print form, no separators;
                                            # a String adds its bytes (this is format!/write!/push_str)
sub add_byte(!self, b: U8)
sub add_char(!self, cp: U32)                # UTF-8 encode; panics on a non-scalar value
sub add_lower(!self, s: String)             # ASCII case map into the buffer (no new allocation per call)
sub add_upper(!self, s: String)
sub insert(!self, at: Int, s: String)
sub remove(!self, a: Int, b: Int)           # delete a byte range
sub truncate(!self, n: Int)
sub clear(!self)                            # keeps capacity
sub reserve(!self, n: Int)
fun replaced(?self, from: String, to: String) -> Text   # → owner
fun into_bytes(<self) -> Vec[U8]            # consume, no copy
fun cstr(?self) -> Vec[U8]                  # NUL-terminated copy for C (settled: explicit) → owner
+t                                          # clone → owner
```

Every read-side operation (`find`, `trim`, `split`, …) is reached as
`?t[..].find(...)`. If that reads too heavily, G6 could let a `Text`
be lent implicitly where a `String` parameter is expected, *with the
`?` still written*: `f(?t)` means `f(?t[..])`, which is the rule arrays
already follow for `[]T` (SPEC §2 "An array goes where a slice is
expected").

### 3.3 `Vec[T]` additions and slice algorithms — prelude

```rig
# element lending (settled)
?v[i] -> ?T,  !v[i] -> !T                    # panics out of range; works for owning T
fun get(?self, i: Int) -> (?T)?              # today T? for Copy T; generalize to a borrow
fun first(?self) -> (?T)?
fun last(?self) -> (?T)?
# writable lookup: !v.get(i) -> (!T)? with G9, else a second name (`slot`)

sub insert(!self, i: Int, x: T)              # takes x: caller writes <x or +x
fun remove(!self, i: Int) -> T               # hands the element out; panics out of range
fun swap_remove(!self, i: Int) -> T          # O(1); the last element fills the hole
fun take_range(!self, a: Int, b: Int) -> Vec[T]  # Rust's drain(a..b), eager → owner
sub truncate(!self, n: Int)                  # drops elements n..
sub extend(!self, xs: []T)                   # copies plain-data elements in (like copy/fill)
sub append(!self, other: !Vec[T])            # moves every element of other in; other is left empty
sub retain(!self, keep: ?fun(?T) -> Bool)    # drops the rejected elements, in order
sub reserve(!self, n: Int)
v.capacity                                    # read-only field
+v                                            # clone: clones each element (+x per element)

# slice algorithms: on ![]T / []T, so arrays, Vecs (through ?v[..] / !v[..]) and slices share them
sub sort(!self)                               # stable, in place, no allocation; uses <;
                                              # Float by IEEE total order
sub sort_by(!self, less: ?fun(?T, ?T) -> Bool)
sub sort_by_key[K](!self, key: ?fun(?T) -> K) # K ordered by <
sub reverse(!self)
sub rotate(!self, k: Int)
fun is_sorted(?self) -> Bool
fun search(?self, x: T) -> Int?               # binary search: index of an equal element
fun lower_bound(?self, x: T) -> Int           # first index with xs[i] >= x (the insertion point)
fun index_of(?self, x: T) -> Int?             # linear, ==
fun contains(?self, x: T) -> Bool
fun min(?self) -> T?                          # Copy T
fun max(?self) -> T?
```

On a `Vec` of owning values, `sort`/`sort_by`/`reverse` must be `Vec`
methods (`!v.sort_by(less)`), because a `![]T` of owning elements is
rejected today (SPEC §2). Its elements are moved by swapping handles,
which `!v.swap` already does.

### 3.4 `Map[K, V]` — prelude

Keys: types with structural `==` and `hash`. That means numbers
except `Float`, `Bool`, `String`, `Text`, plain enums, and plain-data
structs, enums, and optionals of these. Handles are rejected (as `==`
rejects them), and so are floats. Iteration follows insertion order.

```rig
Map()                                        # empty; allocates on first put
Map(capacity: n)
m.len                                        # read-only field
fun get(?self, k: Q) -> (?V)?                # Q is K, or String for a Text key (compiler rule)
fun has(?self, k: Q) -> Bool
sub put(!self, k: K, v: V)                   # takes both; an old value is dropped (key kept)
fun swap_in(!self, k: K, v: V) -> V?         # takes both; hands back the displaced value
fun take(!self, k: Q) -> V?                  # remove, handing the value out; the stored key is dropped
fun slot(!self, k: K, init: V) -> !V         # entry().or_insert: one lookup; k and init are dropped
                                             # if the key exists; lends the value for writing
fun slot_with(!self, k: K, make: ?fun() -> V) -> !V   # or_insert_with: make runs only when absent
sub clear(!self)
fun keys(?self) -> []K                       # contiguous, insertion order (plain-data K)
fun values(?self) -> []V                     # plain-data V
for v, k in ?m                               # value first, then key: Rig's element-first rule
for v, k in !m                               # values writable in place; keys never
for v, k in <m                               # consume
# writable lookup: !m.get(k) -> (!V)? with G9
```

Word count, the canonical entry-API program:

```rig
counts: Map[Text, Int] = Map()
while !words.next() as w
  n = !counts.slot(Text.of(w), 0)      # Rust: *counts.entry(w.to_owned()).or_insert(0) += 1
  n += 1
```

`Text.of(w)` allocates even when the key exists; that cost is visible,
and Rust's `entry` has the same one. A lookup-first form avoids it:
`if !counts.get(w) as n` / `n += 1` / `else` / `!counts.put(Text.of(w), 1)`.
That form depends on G9 (`!m.get`). The lookup with a `String` works
because of the `Q` rule.

### 3.5 `Set[K]` — prelude

```rig
Set()
Set(capacity: n)
s.len
fun has(?self, k: Q) -> Bool
fun add(!self, k: K) -> Bool                  # true when k was new; takes k (dropped if present)
fun take(!self, k: Q) -> K?                   # remove and hand back the stored key
sub clear(!self)
fun items(?self) -> []K                       # insertion order
for k in ?s
# tier 2: union / intersection / difference into a new Set (→ owner)
```

Because `add` returns a `Bool`, an `if` must use the long form
`if (!seen).add(k)` (SYNTAX §5). That is acceptable and already
specified.

### 3.6 `fmt`: formatting to a Text

```rig
# on Text (above): sub add(!self, a, b, ...)    # the whole of format!/write!
Text.fmt(a, b, ...) -> Text                     # format! as a value → owner
# print(a, b, ...) unchanged: spaces between, newline after

# user-defined rendering, by convention, checked per instance:
sub fmt(?self, out: !Text)          # if a struct/enum declares it, print and add use it
                                    # (Rust's Display); the derived form stays available:
fmt.debug(x)                        # a wrapper printing the derived User(name: ...) form (Debug)

# option wrappers: plain-data values that print through the hook, no allocation
fmt.hex(n: U64) -> Hex              # "ff"
fmt.bin(n: U64) -> Bin
fmt.fixed(x: Float, places: Int) -> Fixed         # "3.14"
fmt.pad[T](x: T, width: Int) -> Pad[T]            # right-aligned, space fill
fmt.left[T](x: T, width: Int) -> Pad[T]
fmt.zero[T](x: T, width: Int) -> Pad[T]           # zero fill for numbers
# print(fmt.pad(fmt.hex(255), 4))  ->  "  ff"
```

### 3.7 `io`: stdin, stdout, stderr

```rig
io.write(a, b, ...)                  # stdout, no separators, no newline (print without the spacing)
io.eprint(a, b, ...)                 # stderr, spaced, with newline
io.ewrite(a, b, ...)
io.flush()!
io.read_line(line: !Text) -> Bool!   # replaces line with the next line, without terminator;
                                     # false at end of input; the buffer is reused
io.read_all() -> Text!               # all of stdin → owner
io.read(buf: ![]U8) -> Int!          # raw bytes; 0 at end
io.lines() -> Lines                  # lending iterator over stdin: while !ls.next()! as l
                                     # (next returns String?!; l views the iterator's own buffer)
io.is_tty(fd: Int) -> Bool           # tier 1.5; small and often wanted for colored output
```

Stdout is buffered and flushed at exit, before any read from stdin,
and by `io.flush`. A closed stdout ends the program quietly rather
than panicking.

### 3.8 `fs` (and `path`)

```rig
pub error IoError
  not_found
  permission_denied
  already_exists
  is_dir
  not_dir
  not_empty
  invalid_utf8
  no_space
  interrupted
  other

fs.read(path: String) -> Text!                 # read_to_string, validated UTF-8 → owner
fs.read_bytes(path: String) -> Vec[U8]!        # → owner
fs.write(path: String, data: String)!          # create or truncate
fs.write_bytes(path: String, data: []U8)!
fs.append(path: String, data: String)!
fs.exists(path: String) -> Bool
fs.is_dir(path: String) -> Bool
fs.size(path: String) -> Int!
fs.remove(path: String)!                       # a file
fs.make_dir(path: String)!
fs.make_dirs(path: String)!                    # create_dir_all
fs.remove_dir(path: String)!                   # empty directory
fs.rename(from: String, to: String)!
fs.dir(path: String) -> Dir!                   # lending iterator: while !d.next()! as name
                                               # (name: String view of d's buffer; not . or ..)

struct File                                    # owns an OS handle and a buffer; drop flushes and closes
  File.open(path: String) -> File!             # read
  File.create(path: String) -> File!           # write, truncate
  File.append(path: String) -> File!
  fun read(!self, buf: ![]U8) -> Int!          # 0 at end
  fun read_line(!self, line: !Text) -> Bool!   # as io.read_line
  fun read_all(!self) -> Text!                 # → owner
  sub write(!self, a, b, ...)!                 # variadic like Text.add
  sub write_bytes(!self, data: []U8)!
  sub flush(!self)!
  sub close(<self)!                            # consume; reports flush/close errors that drop can't

# path: functions over String, views except join
path.base(p: String) -> String                 # "a/b.txt" -> "b.txt"
path.dir(p: String) -> String                  # "a/b.txt" -> "a"
path.ext(p: String) -> String                  # "txt" ("" if none)
path.stem(p: String) -> String                 # "b"
path.join(a: String, b: String) -> Text        # → owner
path.is_abs(p: String) -> Bool
```

### 3.9 `os`: process arguments, environment, exit

```rig
os.args() -> []String                 # args[0] is the program; views valid for the whole program,
                                      # like literals: nothing borrowed, nothing allocated per call
os.env(name: String) -> String?       # view valid for the whole program (no set_env exists)
os.cwd() -> Text!                     # → owner
fun main -> Int                       # exit status, returned after every drop and the leak check
os.exit(code: Int)                    # tier 1.5: immediate; runs no drops, skips the leak check
# tier 2: os.run(argv: []String) -> Int!   and a Command builder with captured output (-> Text)
```

### 3.10 `math`

```rig
# generic over numbers, checked per instance (writable today)
math.min[T](a: T, b: T) -> T
math.max[T](a: T, b: T) -> T
math.clamp[T](x: T, lo: T, hi: T) -> T
math.abs[T](x: T) -> T                # panics on Int.min, as - does
math.sign[T](x: T) -> T
math.gcd(a: Int, b: Int) -> Int
math.pow(base: Int, exp: Int) -> Int  # checked: panics on overflow
math.div_floor(a: Int, b: Int) -> Int
math.mod(a: Int, b: Int) -> Int       # floored: result has b's sign (Rust rem_euclid-like)
math.checked_add[T](a: T, b: T) -> T? # and sub, mul: none on overflow

# Float
math.sqrt(x: Float) -> Float
math.cbrt
math.exp
math.ln
math.log2
math.log10
math.pow_f(x: Float, y: Float) -> Float
math.sin
math.cos
math.tan
math.asin
math.acos
math.atan
math.atan2(y: Float, x: Float) -> Float
math.hypot
math.floor
math.ceil
math.round
math.trunc
math.fabs
math.is_nan(x: Float) -> Bool
math.is_inf(x: Float) -> Bool
math.PI
math.E
math.INF
math.NAN

# bits
math.pop_count(x: U64) -> Int
math.leading_zeros(x: U64) -> Int
math.trailing_zeros(x: U64) -> Int
```

### 3.11 `time`

```rig
type Duration = Int                    # nanoseconds; +, -, *, <, print just work
time.NS
time.US
time.MS
time.SECOND
time.MINUTE                            # Duration constants: 5 * time.SECOND

struct Instant                         # plain data: a monotonic reading
  time.now() -> Instant
  fun elapsed(?self) -> Duration
  fun since(?self, earlier: Instant) -> Duration

time.sleep(d: Duration)
time.unix() -> Duration                # wall clock: ns since 1970 (SystemTime); may be negative
time.secs(d: Duration) -> Float        # for printing: time.secs(t.elapsed())
```

### 3.12 `random`

```rig
struct Rng                             # plain data (xoshiro256** state); deterministic per seed
  Rng.seeded(seed: U64) -> Rng
  Rng.new() -> Rng                     # seeded from OS entropy
  fun next(!self) -> U64
  fun int(!self, lo: Int, hi: Int) -> Int     # uniform in lo..hi (end excluded), unbiased
  fun float(!self) -> Float                   # uniform in [0, 1)
  fun chance(!self, p: Float) -> Bool
  sub shuffle[T](!self, xs: ![]T)             # Fisher-Yates via !xs.swap
  fun pick[T](!self, xs: []T) -> T?           # Copy T
random.fill(buf: ![]U8)                # OS CSPRNG bytes (getrandom / arc4random)
```

---

## 4. What each tier-1 item still needs

### Gap definitions

| ID | Gap | Kind | Evidence |
|---|---|---|---|
| G1 | Call a method or read a field on a generic `T` | L | probe g1/g8: "a generic parameter `T` has no methods" |
| G2 | Lend elements of a Vec of owning values: `?v[i]`, `!v[i]`, `v[0].n`, `?self.items[i]` in a generic body | L | probe g2: "indexing a `Vec[*B]` would copy an owning element out"; g7: "copies an element out of a Vec that holds a `T`" |
| G3 | A Vec of owning non-handle values: `Vec[Vec[T]]`, `Vec[Text]`, `Vec[Pair[String, Res]]` | L | probe g3/h3: `Vec[T]` requires Copy, plain data, `*T`, `~T`, or `Box[T]` |
| G4 | Lend a `*T` as a `?T` | L | probe g4: "expected `?B`, got `?*B`" |
| G5 | Attach an error set to a function (`-> Int!Parse`) | L (documentation quality, not blocking) | probe g5: parse error |
| G6 | A `String` that borrows an owner: `?t[..]` of a `Text` as a `String` with provenance, so a view can't outlive or alias a write to its `Text` | L | ROADMAP: "A slice of a built (heap) string will be a borrow of it"; today every String is free to copy |
| G7 | Converting `[]U8` to `String` (validated or not), and printing a `[]U8` | L/B | probe h1: "expected `String`, got `[]U8`"; SPEC §17 rejects printing `[]U8` |
| G8 | Read-only public fields (or computed members), so library types keep the `.len` convention without letting callers write `t.len = 5` | L | SPEC §14: a member is `pub` (read and write) or private |
| G9 | One method name, two receiver modes: `v.get(i) -> (?T)?` and `!v.get(i) -> (!T)?`, chosen by the call's sigil (no `_mut` twins) | L (optional; the fallback is a second name) | design |
| G10 | Tuples or multiple results (`cut`, `split_at`, `div_mod`) | L (optional; a generic `Pair[A, B]` works today, as probe h2 shows) | no tuples in SPEC/SYNTAX |
| G11 | FFI slices: `[]U8` as pointer plus length to C | L (settled, not built) | SPEC §15: only integers, floats, and `Bool` cross |
| G12 | A sanctioned way for stdlib Rig code to call runtime (Zig) primitives that take slices and Strings, since `raw` + `extern` reaches only C with scalars | L/B | SPEC §15; `zig "..."` reserved |
| G13 | Finding std modules: `use` finds only `name.rig` beside the root file | L (tooling) | SPEC §14 |
| G14 | Process state in the runtime: emitted `main` takes `std.process.Init` (args, environment, `Io`) and stores it | B | docs/zig-0.16.md §4 |
| G15 | Variadic library calls (`Text.add`, `io.write`, `File.write`); users can't declare variadics and there are no macros | B | `print` is the only variadic |
| G16 | Conditional compilation by OS (for libc-based code written in Rig) | L (roadmap) | ROADMAP |
| G17 | `print`/`add` honoring a user `fmt(?self, out: !Text)` method, checked per instance | B (needs G1's machinery) | design |
| G18 | A structural `hash` builtin specified like `==` (String and Text by content; handles and floats rejected) | B | design |
| G19 | Ordering structs by a `less`/`cmp` convention | L (after G1); closures suffice for tier 1 | SPEC §5: `<` orders numbers, Strings, `[]U8` |

Other things probed that **already work** and that the stdlib can lean
on:

- generic structs with `Vec[T]` fields;
- `for p in !self.slots` writing fields of plain-data elements;
- struct iterators holding a `[]T` or `String` with `next(!self) -> T?`
  (probes i1, i2);
- `T?!` results;
- `?fun` comparator parameters (examples/sort.rig);
- `(?T)?` returns from a generic struct;
- `Vec[Box[T]]` of owning structs (probe m2);
- `extern fun sqrt(x: F64) -> F64` and `time`/`getpid` inside `raw`
  (probe m4);
- `*%` wrapping arithmetic for hashing and a PRNG (probes h4, i3);
- binary search generic over `<` for Int and String (probe i4).

### Per-item status

| # | Item | Status | What it needs |
|---|---|---|---|
| 1 | `String` methods (find, trim, cut, split/lines/words iterators, ASCII) | **R** as free functions in a module today. **B** to be methods on the built-in type. | G6 (so views of a `Text` stay safe). `Float.parse` needs **B** (correctly rounded parsing: Zig's `std.fmt.parseFloat`); `Int.parse` is **R** (with `I128` or wrapping plus checks) |
| 2 | `Text` | **L + B** | Storage is **R** (a struct around `Vec[U8]` works: probe g6), but it can't be turned into a `String`, printed, or compared (G7). Also G6 (`?t[..]` as a borrowing String), G8 (`.len`), G15 (variadic `add`), G11 for `cstr`. Best done as a runtime type like `Vec` |
| 3a | `Vec` additions for Copy/plain `T` (insert, remove, truncate, extend, retain, take_range, reserve) | **B** | Users can't add methods to built-in `Vec`; each is a few lines in `runtime.zig` plus sema signatures |
| 3b | `Vec` additions for owning `T` (`?v[i]`, `get -> (?T)?`, `first`, `last`, `remove -> T`, `retain` over `?T`) | **L** | G2; G3 for `Vec[Text]`/`Vec[Vec[T]]`; G9 for `!v.get` |
| 3c | Slice algorithms on plain data (sort, sort_by, sort_by_key, reverse, search, lower_bound, index_of, min/max) | **R** today as generic free functions (examples/sort.rig, probe i4). **B** to be methods on `[]T`/`![]T`, and for a fast stable in-place sort (Zig's `std.sort.block`) | Float total order in `sort`: B |
| 3d | Sorting a `Vec` of owning values | **L** | G2 (lend `?v[i]` to the comparator); `!v.swap` already moves handles |
| 4 | `Map[K, V]` | **B** now: a runtime generic type over Zig's `ArrayHashMap` with a structural hash/eql context, as `Vec` wraps `ArrayList` | G18 (hash), G2's machinery for `(?V)?`/`!V` lending of owning values, G9 for `!m.get`. As **R** it needs G1 or G18, plus G3 for owning keys and values (probe h2 shows a linear-scan map is R today for Copy K and V) |
| 5 | `Set[K]` | **B** (as Map) | same as Map |
| 6 | `fmt` (`Text.add`, `Text.fmt`, `fmt` hook, hex/pad/fixed) | **B** | G15 (variadic), G17 (hook), G1 for the `fmt` convention. The option wrappers are **R** once G17 exists. Float `fixed` formatting needs **B** (Zig's float formatting) |
| 7 | `io` (write, eprint, flush, read_line, read_all, lines) | **B** | G14 (the runtime's `Io`), G15 (variadic write). As **R** it needs G11 + G12 or G16 (libc `read(0, buf, n)`) |
| 8 | `fs` + `File` | **B** for the primitives; the `File` struct with `drop`/`close(<self)` shape is **R** | G11/G12 (pass paths and buffers), G14 (`Io`), G15 (variadic write), G5 to document `IoError` (optional). `fs.dir` as a lending iterator avoids G3; a `list -> Vec[Text]` would need G3 |
| 8b | `path` helpers | **R** today (String slicing and `find_byte`) | `path.join -> Text` needs item 2 |
| 9 | `os` (args, env, cwd, `main -> Int`, exit) | **B** | G14. `fun main -> Int` is a small language change in main's accepted signatures (L). `os.exit` must skip the leak check |
| 10 | `math` integer and generic functions | **R** today (probes; generic `<`) | none |
| 10b | `math` float functions | **R** today through `extern` libm inside `raw` (probe m4), but the platform must link libm. **B** preferred: add the pure Zig builtins `@sqrt @sin @cos @tan @exp @exp2 @log @log2 @log10 @abs @floor @ceil @trunc @round @popCount @clz @ctz` to the safe list (today they aren't even allowed in `raw`) | one sema table change |
| 11 | `time` | **B** | `clock_gettime` takes a struct pointer (G11/G12), or Zig 0.16's `std.Io.Clock.Timestamp.now(io, …)` (G14). `Duration` math and `Instant` arithmetic are **R** |
| 12 | `random` | `Rng` is **R** today (probe i3: splitmix64 runs); `Rng.new` and `random.fill` need **B** (Zig's `io.random`) or G11 + G16 | none beyond entropy |

### The ordering this suggests

1. **Low-risk builtins, no language change.** Widen the safe builtin
   list (item 10b); add `Vec` methods for plain `T` (3a); add
   `os.args`/`os.env` (G14); add `io.write`/`eprint`/`read_line` into
   `Vec[U8]`. Write `math`, `random.Rng`, slice algorithms, and the
   `path` helpers in Rig. Settle G13 so these can live in a `std`
   directory.
2. **`Text` (G6, G7, G8, G15).** This is the one real language
   design: `String` gains borrow provenance when it comes from a
   `Text`. It gates `fmt`, `fs.read`, `io.read_line`, and `Map[Text,
   V]`.
3. **Owning elements (G2, G3, G4).** `?v[i]`/`!v[i]`, `Vec` of owning
   values, and `*T` lent as `?T`. These unlock sorting and lookup over
   owning values and `Map` values that own.
4. **`Map`/`Set` (B, with G18).** Insertion-ordered.
5. **G1 (method calls on a generic `T`, checked per instance).** This
   turns the `fmt` hook, custom `hash`/`eq`, `less`/`cmp`, and "any
   reader" into conventions rather than builtins. G9 and G5 are
   polish.
