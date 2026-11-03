# Idiom expert: the Rig idiom map for the four Rust ports (2026-10-29)

Every Rig form below was probed with `bin/rig` built from main
(`1b2f4b59d`). Probe files are in `rust-ports/idiom-probes/` (named in
the last column); "doc" means the form is a tested doc example I did not
re-probe. Nothing in the checkout was changed.

## 1. The idiom map

| Rust | Rig | Probed one-liner | Notes |
|---|---|---|---|
| `Option<Box<Node<T>>>` | `^Node[T]?` | `next: ^Node[T]?` (second) | One owner, nullable pointer. Long chains drop without recursion: a 1,000,000-node stack drops clean (second). |
| `Box::new(Node{..})` | `^Node(...)`; `^<x` boxes an owner; `^f(x)` boxes a result | `@head = ^Node(elem: <elem, next: <@head)` (second) | `^make(d - 1)` boxes a call's result (bt). |
| `self.head.take()` | `<@head`: takes an optional field and leaves `none` | `if <@head as box` (second) | One character for `take()`. Works on any optional place you may write. |
| `Box` contents moved out | `<box.unbox()` | `node = <box.unbox()` then `<node.elem` (second) | `<node.elem` straight through a box is rejected with that hint. One extra line per `pop`. |
| `mem::replace(&mut x, v)` | `old = swap(!place, v)` | `old = swap(!p.left, String("c"))` (S_select_swap) | `swap(!a, !b)` swaps two places. |
| `as_ref().map(\|n\| &n.elem)` | `if ?@head as node` then `return ?node.elem`; result `(?T)?` | `fun peek(?@) -> (?T)?` (second) | `as_ref`/`as_mut`/`map` all become `if ?o as x` / `if !o as x`. |
| `as_mut().map(\|n\| &mut n.elem)` | `fun peek_mut(!@) -> (!T)?` | `if (!s).peek_mut() as v` / `v *= 10` (second) | |
| `opt.unwrap_or(d)`, `opt?` | `o ?? d`, `e?`, `x = o ?? return none` | `old = <@head ?? return none` (fifth) | `?? return` is the idiom for early-out pops. |
| `Rc<T>` | `*T` (count not atomic) | `PList(head: *Node(elem: <elem, next: +@head))` (third) | `+h` is `Rc::clone`. A task given one is made local, pinned to one thread (`rig check --tasks` says so). |
| `Arc<T>` (immutable) | `*Frozen[T]` | `next: *Frozen[Node[T]]?` (third_arc) | Same code as `Rc` with `*Frozen(...)`; crosses to any core. Exactly third-arc.md. |
| `Rc<RefCell<T>>` | an object behind `*` whose changing fields are `Cell[...]`; or `*Cell[T]` | `next: Cell[*Node[T]?]`, `!old.next.set(+node)` (fourth, fifth) | Change is a marked call (`set`, `swap`). No runtime borrow flag, so no `BorrowMutError`. |
| `Weak<T>`, `upgrade()` | `~h`, `*w` | `!old.prev.set(~node)`; `if w as weak and *weak as prev` (fourth) | The deque's back links. |
| `Rc::try_unwrap(rc).ok().unwrap().into_inner()` | none; hold the element as `Cell[T?]` and `(!c).swap(none)` | `(!old.elem).swap(none)` (fourth) | **Gap G4.** |
| `Ref::map(node.borrow(), \|n\| &n.elem)` | a view of a plain field of a `*T`: `?n.elem` | `fun peek(n: ?*Node) -> ?String` / `?n.elem` (L2) | Works only for a field that is not in a `Cell` (L). With G4 that forces a choice: peekable or poppable, not both. |
| `Iter<'a, T>` | an object holding `(?Node[T])?`, `fun next(!@) -> (?T)?` | `for x in ?s.iter()` (iter) | No lifetimes. The `?` before `s.iter()` is required and the error says so. |
| `IterMut<'a, T>` | none as an object; a closure walk, `sub each_mut(!@, f: ?sub(!T))`, written recursively | `each_mut(!head, \|x\| x *= 10)` (im4) | **Gap G2**: no value holds a write view, and a write cursor cannot advance in a loop. |
| `IntoIter<T>` | an object owning the list, `next = (!@list).pop()` | `it = <s.into_iter()` / `for x in !it` (itermut2) | `for x in <s.into_iter()` is read as the loop's `<` mode, so bind first. |
| `while let Some(x) = it.next()` | `while (!it).next() as x` / `for x in !it` | doc (SPEC for) | |
| `impl Drop for List<T>` | not needed: box and handle chains drop without recursion | 1M-node drops in second, third, fifth | `drop(!@)` is rejected on a generic object (A); none of the four needs one on a generic type. |
| `impl Drop` (non-generic, e.g. `DbDropGuard`) | `drop(!@)` | doc (01-sigils) | mini-redis's purge-task shutdown. |
| `unsafe` raw pointers (fifth's tail pointer) | none; the safe form is `*Node` with `Cell[*Node?]` next and a `tail` handle | `@head = (!old.next).swap(none)` (fifth) | **Gap G5**: "Rig has no raw pointers yet" (SPEC §15). The safe queue runs a 1M push and drop clean. |
| `Box<dyn Trait>` | `^{A}` | `world: List[^{Hittable + Syncs}]` (ray) | `+ Syncs` is what lets `par.map` read the world from every core. |
| `Arc<dyn Trait>` | `*{A + Syncs}` from `*Frozen(...)`; one thread: `*{A}` | `m: *{Material + Syncs} = *Frozen(Metal(a: 0.5))` (H) | For the ray tracer, an `enum Material` held by value is simpler and faster (ray). |
| trait + generic `fn f<T: Tr>` | `api A`, `obj S: A`, `fun f[T: A](...)` | `fun hit(?@, r: Ray, lo: Float, hi: Float) -> Hit?` (ray) | An API method that returns something holding a view must say `from @` (J). |
| `HitRecord<'a> { mat: &'a dyn Material }` | `obj Hit { mat: ?Material }`, `-> Hit? from @` | `Hit(t: x, mat: ?@mat)` (J) | The natural home of `from`. |
| `Copy` `Vec3` with `impl Add/Sub/Mul` | `type Vec3 = Simd[Float, 4]`: `+ - *`, scalars splat | `c = a + b * 2.0 - a`; `v * (1.0 / len)` (vec) | No operator overloading for objects (`Num` is built-in only). `Simd` has no `/` and no lane sum (P, Q): dot is `p[0] + p[1] + p[2]`. |
| `[Planet; 5]`, `split_at_mut` pair loop | `![5]Body`, index both: `bodies[i].vel -= ...` | `bodies[j].vel += d * (bodies[i].mass * mag)` (nbody) | Emits plain `bodies.*[i].vel -= d * @splat(...)`. `for b in !bodies` for the drift step. |
| `Vec<T>` | `List[T]` | `!v.push(x)`, `(!v).pop()`, `for x in !v` (doc) | |
| `HashMap<Vec<u8>, usize>`, `entry().or_insert(0) += 1` | `Map[?String, Int]`, keys are views into the input | `(!m).ensure(?data[i..i + k], 0) += 1` (knuc) | Zero-copy keys, which Rust's version cannot write without lifetimes. |
| `HashMap.get_mut` | `(!m).edit(k)` | `if (!@subs).edit(key) as list` (db) | |
| `&[u8]`, `&str` | `[]U8`, `?String` (bytes), `s[a..b]` | `gc(?bytes[1..])`, `gc_text(s[0..3])` (G) | |
| `Bytes` (refcounted, cloned to many) | `String` when owned once; `*Frozen[String]` when sent to many | `!a.send(+msg)!` with `msg = *Frozen(String("hello"))` (E) | |
| `Result<T, E>`, `?` | `T!E`, `e!`, `catch`; error sets with fields | `return Frame.integer(n: n), next` in `-> (Frame, Int)!Parse` (D) | Rust's `?` maps to Rig's `!`; Rig's `?` is absence only. |
| `Result<Option<Frame>>` | `Frame?!` | doc (03-errors `Int?!`) | `read_frame`. |
| `enum Frame { Array(Vec<Frame>), .. }` | `enum Frame` with `array(items: List[Frame])` | (D) | `error` is a keyword, so a variant can't be named `error` (D). |
| `match` with block arms | `pattern` + indented block (no `=>`) | `'*'` arm parsing an array (D) | |
| `tokio::spawn(async move {..})` | a named function as a task: `!conns.add(handle(+db, <s)&)` | (server) | Only named calls become tasks. `Tasks[Void!]` drops each task that ended well as the next is added (reap). |
| `Arc<Mutex<State>>` | `*Actor[State]` | `(!db).publish("news", "hello")!` (db) | No lock to forget to release; the actor's methods run one at a time. |
| `broadcast::channel` | a `List[*Chan[T]]` per key inside the actor | `(!@subs).ensure(<key, List()).push(+ch)` (db) | **Gap G7**: no broadcast and no `try_send`, so a full subscriber blocks the actor. |
| `mpsc::channel` | `*Chan[T](n)` | `while (!ch).recv()! as m` (db, E) | |
| `select!` over channels | `task.select((!a).on_recv(f), ...)` | (S_select_swap) | **Gap G6**: no socket arm and no split stream, so `select!{ read_frame, shutdown }` has no form. |
| `Notify` + `sleep_until` | `time.within[Int?](ns, \|+wake\| (!wake).recv()!)` | (K) | Needs `[Int?]` spelled: `R` is not inferred from the closure. |
| shutdown: `broadcast<()>` + `mpsc` completion + `Shutdown` struct | `sub main()!`: Ctrl-C cancels main; dropping the `Tasks` set cancels and waits for every connection | (reap, server; doc 04) | All of `shutdown.rs` and its plumbing dissolves. |
| `Semaphore` (connection limit) | none; a `*Chan[Int](250)` of tokens is the closest | unprobed | **Gap G8** (small). |
| `BTreeSet<(Instant, String)>` | none; a sorted `List` with `sort.lower_bound` | unprobed | **Gap G9**: no ordered map or heap. |
| rayon `into_par_iter().map().collect()` | `par.map(?xs, f)` | `par.map(?depths, \|+max, depth\| churn(depth, max))` (bt) | Over a range it is rejected (sn): build a `List` of indices. |
| rayon `par_iter_mut().enumerate()` | `par.each(!xs, f)`, no index | (sn2) | **Gap G10**: no index in `par.each`. |
| per-thread RNG under rayon | `par.workers(!rngs, ?rows, \|r, y\| ...)` | doc (STD par) | |
| `typed_arena::Arena` | `^Tree` boxes and the per-thread release allocator | (bt) | `Table` can't stand in: it never shrinks and has no `clear`. |
| `thread::spawn` + `join` | `t = f(?data, k)&`, `>t`; `Tasks[T]`, `>ts` | 7 tasks lend `?data` to read at once (knuc) | No `Arc` needed to share the input: the loan is the proof. |
| `rug::Integer` (in place) | `std.bigint` (each op allocates; there is no `div`) | (pi) | **Gap G11**: pidigits can't be written. |
| `regex` crate | none | — | **Gap G12**: regexredux can't be written. |
| `println!("{:.9}", x)` | none | (fmt) | **Gap G13**: no fixed-precision float format, which nbody, spectralnorm, and knucleotide need. |
| `FnOnce` callback (silly2) | `once ?fun(?Frame) -> U` | `push(none, 1, \|a\| push(a, 2, \|b\| ...))` (C6) | The natural home of `once ?fun`. Generic version: **bug B1**. |
| owned parameter mutated (`mut s: TcpStream`) | `new s = <s` on the first line | (server) | Papercut P1. |
| `#[derive(Clone)]` | automatic `+x` | `b = +a` (I) | |
| `mut` on a constant, `const` | `x =! e`, module `NAME = e` | doc | |
| compile-time table (`static COMP: [u8; 256]`) | `fun complement[n: Int] -> [n]U8`, `COMP = complement[256]` | (F) | Emits a literal `[256]u8`. |
| SSE byte shuffle (fannkuch-6) | `Simd[U8, 16].lookup(mask)` | `cur = cur.lookup(masks[Int(cur[0])])` (fk) | One `pshufb`/`tbl` per flip. |
| mandelbrot 8 pixels to a byte | `Simd[Float, 8]` compare, then `.bits()` | `U8((tr + ti <= 4.0).bits())` (mb) | `bits()` puts lane 0 in bit 0; P4 wants it in bit 7, so reverse the byte or the lanes. |
| raw stdout bytes | `file.write("/dev/stdout", buf)!` | (knuc) | `print` adds a newline. |
| stdin | `file.read("/dev/stdin")! ?? String()` | (knuc) | |

## 2. Gaps and bugs, each with its smallest probe

**B1 (bug, breaks North Star 1).** A generic object holding an optional
view of its own type is accepted by `rig check`, then Zig fails.

```rig
obj Frame[T]
  data: T
  prev: (?Frame[T])?

sub main()
  a = Frame(data: 1, prev: none)
  b = Frame(data: 2, prev: ?a)
  print(b.data)
```
`rig check` passes. `rig run` gives: `rig/runtime.zig:802:12: error:
type '__rig_main.Frame(i64)' depends on itself for type information
query here`. The non-generic `obj Frame` with `prev: (?Frame)?` runs
(C2), and so does `^Frame[T]?` (C5). This blocks the generic silly2.

**G2. No `IterMut`, and no loop that walks a list by writing.**
```rig
sub bump_all(head: !^Node?)
  cur = !head
  while !cur as node
    node.elem += 1
    cur = !node.next
```
`O.rig:9:5: error: cannot reassign 'cur' while it is lent`. A write view
can't be held in a field (`(!Node[T])?` is rejected: "a write view is
never stored inside a value"). What works: recursion,
`sub each_mut[T](link: !^Node[T]?, f: ?sub(!T))` (im4), which uses one
stack frame per node. Rust's NLL accepts this loop. The question for the
owner: should moving a write cursor forward (`cur = !node.next`, where
`node` came from `cur`) be accepted?

**G4. No `Rc::try_unwrap`.**
```rig
obj Node
  elem: String?

fun take(n: *Node) -> String?
  new n = <n
  <n.elem
```
`error: cannot take through a shared handle (*T); other handles may
exist`. A `Cell[T]` element can't be viewed either (L), so a
doubly-linked deque of owned `T` can pop or peek but not both. Candidate
form: `(<h).unshare()`, giving `T?`: the value when this is the last
strong handle, else `none`.

**G5. No raw pointers** (SPEC §15). fifth.rs has no literal Rig form.
The safe `*Node` + `Cell` queue (fifth) is the port. It costs a count
and a weak count per node, against Rust's bare pointer.

**G6. `select!` can't include a socket read, and a stream can't be
split.**
```rig
t = reader(!s)&
(!s).write("pong")!
```
`error: use of 's' while a write loan is live` (split). `task.select`
takes only channel arms (`no method 'on_read' on type 'Stream'`, sel).
This affects mini-redis's handler (`read_frame` against shutdown, which
cancellation covers) and **subscribe mode** (`read_frame` against
messages, which cancellation does not cover). Smallest fix:
`(<s).split() -> (Reader, Writer)`. Then one task reads frames into the
same channel the subscriptions feed.

**G7. No broadcast and no `try_send`.** A publish from inside the actor
blocks while one subscriber's channel is full. tokio drops the lagging
messages and reports `Lagged`.

**G8. No semaphore.** **G9. No ordered map or heap** (mini-redis
expirations). **G10. `par.each` gives no index, and `par.map` takes no
range** (`a range 'a..b' can only be used as a 'for' loop source`, sn).

**G11. `BigInt` has no `div`** (`no method 'div' on type 'BigInt'`, pi),
no multiply by a small integer, and no in-place forms. pidigits needs all
three to be fast.

**G12. No regex.** regexredux is out of scope until a std.regex exists.

**G13. No fixed-precision float format.** `text.format_float` doesn't
exist (fmt). Every float benchmark prints `{:.9}`. It is a one-function
std addition.

**G14. `Simd` has no `/` or lane sum** (P, Q). spectralnorm's SIMD
version divides lane by lane. The workaround is a reciprocal per lane.

**Papercuts.**
- P1: an owned parameter can't be changed without `new s = <s` (server).
- P2: `a, b = f() catch |e|` followed by a block that returns is
  rejected; only `catch return` on one line is accepted (D).
- P3: `time.within(ns, closure)` needs `[R]` spelled out (K).
- P4: `COMP['A']` is rejected ("an index must be an integer; got
  Static"), so a byte literal can't index (F).
- P5: a method and a field can't share a name (`head` in third).
- P6: `List` is reserved, so the book's `List<T>` types become `Stack`,
  `PList`, `Deque`, `Queue`.
- P7: `for x in <s.into_iter()` parses as the loop's `<` mode.
- P8: `for line in par.map(...)` over Strings needs binding to a name
  first.

## 3. Sigil ledger forecast

| Sigil or form | Natural home | Strength |
|---|---|---|
| `x = e`, `@`, `?x`, `!x` | all four | everywhere |
| `x =! e`, module constants | benchmarks (`SOLAR_MASS`, `COMP`), mini-redis limits | common |
| `<x` (move, take a field) | lists (`<@head` is `take()`), mini-redis (streams into tasks, keys into maps) | defining |
| `+x` | third (`+@head`), mini-redis (`+db` per connection), binarytrees `\|+max\|` | common |
| `^x`, `^T`, `<b.unbox()` | second, silly1, binarytrees, ray tracer's `^{Hittable}` | strong |
| `*x`, `*T` | third, fourth, fifth (safe queue) | strong in lists only |
| `~x`, `*w` | fourth's `prev` | **one home** |
| `T?`, `?? `, `if o as x` | everywhere | defining |
| `e?` | mini-redis parse helpers | light |
| `T!`, `e!`, `catch`, error sets with fields | mini-redis (Frame and Parse errors, `Frame?!`), benchmark `main()!` | strong |
| `f(x)&`, `>t`, `Tasks` | knucleotide, mini-redis connections | strong |
| `*Actor` | mini-redis Db | one home, central |
| `*Chan`, `task.select` | mini-redis pub/sub, purge wake | strong (select limited by G6) |
| `*Frozen` | third-arc, mini-redis published payloads | real |
| `Cell` | fourth, fifth; mini-redis counters | real |
| `par.map`, `par.each`, `par.workers` | ray tracer (`workers` with a `Random` per worker), binarytrees, mandelbrot, spectralnorm | strong |
| `Simd` (`lookup`, masks, `bits`) | nbody, mandelbrot (`bits`), fannkuch (`lookup`), ray tracer `Vec3` | strong; the benchmarks show it off |
| `api`, `obj S: A`, `[T: A]` bounds | ray tracer `Hittable` | one home |
| `^{A}` | ray tracer world | one home |
| `?{A}` | ray tracer, if `HittableList` is itself a `Hittable` | weak |
| `from` | ray tracer `-> Hit? from @` (required); mini-redis line slicing | real but rare |
| `once ?fun` | silly2's callback | **one home** (frozen form, finds its use) |
| closure captures `\|?x\| \|+x\| \|!x\|` | par closures, silly2, `time.within` | common |
| enums with fields, `match` | mini-redis `Frame`, `Command`; ray tracer `Material` | strong |
| several results | mini-redis `parse -> (Frame, Int)!`, line helpers | real |
| compile-time `[n: Int]` functions | revcomp complement table, fannkuch masks (but a module constant can't hold a vector) | light |
| `Iter` (`next(!@)`) | lists | strong |
| `drop(!@)` | mini-redis guard only (generic objects can't have one) | light |
| `Table`/`Slot` | knucleotide dense k-mer counts (`Table[U32, 1 << 24]`, zeroed lazily) | **weak**; binarytrees can't use it (never shrinks) |
| `defer` / `errdefer` | mini-redis connection logging | weak |
| **No natural home** | `keeps`, symbols `:name`, `*{A}` and `~{A}` (an enum or `*{A + Syncs}` serves better), `!{A}`, `\|~x\|`, `*fun` owned closures, `Signal`, `raw` (no raw pointers, and FFI carries only integers, so GMP and PCRE are out), `x.not()`/saturating ops, `unique` user objects | evidence for the owner, not a cut |

## 4. Port sketches

### too-many-lists → `compare/rig/too-many-lists/`
One file per chapter. `List` is reserved, so the types are renamed.
- `first.rig`, `second.rig`: `obj Node[T] { elem: T; next: ^Node[T]? }`
  and `obj Stack[T] { head: ^Node[T]? = none }`; `push`, `pop` (`<@head`
  plus `unbox`), `peek -> (?T)?`, `peek_mut -> (!T)?`, objects `Iter[T]`
  (`(?Node[T])?`) and `IntoIter[T]` (owns the stack). `iter_mut` becomes
  a recursive `each_mut(!@, f: ?sub(!T))` (G2). No `drop`. Shows
  `^ < ? ! @ T? as ??` and the `Iter` protocol. Ownership: one owner (box).
- `third.rig`: `obj PList[T] { head: *Node[T]? }`, `prepend(?@)`, `tail`,
  `first`, `Iter`. Ownership: shared and immutable (`*T`). A second
  variant with `*Frozen[Node[T]]` is the Arc chapter, with a task
  reading it from another core. Shows `* +`.
- `fourth.rig`: `obj Node[T] { elem: Cell[T?]; next: Cell[*Node[T]?];
  prev: Cell[~Node[T]?] }` and `obj Deque[T] { head, tail: *Node[T]? }`
  with `push/pop_front/back` and `IntoIter`. Peek only for plain `T`
  (G4). Shows `~ *w Cell swap`. Ownership: shared and changing, weak back
  links.
- `fifth.rig`: the safe queue, `*Node[T]` with a `Cell` next and a tail
  handle. The write-up says why there is no `raw` (G5).
- `silly1.rig`: a zipper of two `Stack[T]`s moving boxes,
  `pop_node -> ^Node[T]?` and `push_node(^Node[T])` (B). Shows box moves.
- `silly2.rig`: a stack-frame list with `once ?fun` callbacks (C6). It
  needs B1 fixed before it can be generic.

### Benchmarks Game → `compare/rig/benchmarksgame/{name}/`
- binarytrees: `obj Tree { left, right: ^Tree? }`, `par.map` over the
  depths; the boxes go to the per-thread allocator. Output matches
  `10_out` (bt).
- nbody: `type V = Simd[Float, 4]`, `obj Body { pos, vel: V; mass }`,
  `[5]Body`, index-pair loop. Blocked only by G13.
- spectralnorm: `par.map` over a `List` of indices, scalar inner loop
  (G10, G14, G13).
- mandelbrot: `Simd[Float, 8]` per output byte, `.bits()`, `par.map` per
  row, `file.write("/dev/stdout")`.
- fannkuchredux: `Simd[U8, 16]` permutation, flip by `lookup` with
  precomputed masks; `par.map` over the first-index blocks.
- fasta: an LCG object, cumulative tables, a 60-column line buffer
  `String`; plain loops.
- knucleotide: `Map[?String, Int]` keyed by views, 7 tasks lending
  `?data` (knuc). Optionally a `Table` of 2-bit codes for k ≤ 12.
- revcomp: the compile-time `COMP` table, reverse in place by byte
  swaps, one output buffer.
- pidigits: wait for G11. regexredux: out of scope (G12).

### Ray tracer → `compare/rig/ray-tracing/` (written from Shirley's book)
`vec.rig` (`type Vec3 = Simd[Float, 4]`, `dot`, `cross`, `unit`),
`ray.rig` (`obj Ray`), `material.rig` (an `enum Material` of
lambertian, metal, and dielectric held by value, and `scatter(?@, ...) ->
(Ray, Vec3)?`, several results), `hit.rig` (`api Hittable`, `obj
Sphere: Hittable`, `obj Hit { mat: ?Material }` with `from @`),
`camera.rig`, `main.rig` (`List[^{Hittable + Syncs}]`, and
`par.workers(!rngs, ?rows, ...)` with one `random.Random` per worker).
Shows `^{A}`, `api`, `from`, `Simd`, `par`, and `|?world|`.

### mini-redis → `compare/rig/mini-redis/`
`frame.rig` (`enum Frame`, `error Parse { incomplete; invalid(at) }`,
`parse(?String, Int) -> (Frame, Int)!Parse`), `cmd.rig` (`enum Command`
of get, set, publish, subscribe, unsubscribe, ping, and unknown;
`from_frame`), `db.rig` (`obj Db { entries: Map[String, Entry]; subs:
Map[String, List[*Chan[*Frozen[String]]]]; expirations: List }`, behind
`*Actor[Db]`; a purge task woken by `*Chan[Int](1)` plus `time.within`;
`drop(!@)` on the holder), `conn.rig` (a `net.Stream`, a read buffer, and
`read_frame -> Frame?!`, `write_frame`), `server.rig` (`sub main()!`,
`net.listen`, `Tasks[Void!]` per connection, `!conns.add(handle(+db,
<s)&)`). Ctrl-C does the whole shutdown. The client and the CLI are
optional. Subscribe mode waits on G6; until then it polls with a short
`time.within` on the socket read. Shows `*Actor *Chan *Frozen & > Tasks
T?! errors match + <`.

## 5. Decisions (defaults)
1. Arc is `*Frozen[T]`, and `Arc<Mutex>` is `*Actor[T]`. [yes]
2. The ray tracer's materials are an enum held by value, not
   `*{Material + Syncs}`. [enum; mention `*{A}` in the write-up]
3. fifth.rs is ported as the safe `*Node` queue, and the write-up
   explains the missing raw pointers. [yes]
4. `IterMut` is a recursive `each_mut` closure walk, and G2 goes to the
   owner as a question. [yes]
5. Fix B1 first, from a failing case, in its own worktree. [yes]
6. Small std additions before the benchmarks: `text.format_float(x,
   digits)` (G13), `BigInt.div` or `divmod` (G11). Each needs the owner's
   OK as std scope. [ask]
7. mini-redis's subscribe mode waits on `Stream.split` (G6), a design
   question for the owner; polling stands in until then. [ask]
