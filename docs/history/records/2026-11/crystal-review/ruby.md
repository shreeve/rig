# Crystal through a Ruby lens, and what Rig should take

Reviewer: a Ruby expert. Source: `~/Data/Code/rig/misc/crystal` (1.23.0-dev).
Paths below are relative to that tree. Rig docs read from `origin/main`.

## Summary

Crystal keeps more of Ruby's joy than any other compiled language: blocks
read as Ruby's, `Enumerable` is nearly whole, interpolation, `?` names,
`property`, and `case`/`when` all survive. It pays for this with
whole-program type inference (slow, non-incremental builds, long
instantiation traces), a context-heavy hand-written parser, a GC, and
unstructured fibers. The Ruby idioms that break under static types are
the dynamic ones: `send`, `define_method`, runtime `method_missing`,
`eval`, and anything that grows a class at run time; Crystal moves them
into macros, which work but are a second language.

## Scores

| Area | Score | Why |
|---|---|---|
| Syntax | 8 | The closest a compiled language gets to Ruby's feel (blocks, `&.`, optional parentheses, interpolation), marred by `end` noise and whitespace-decided calls (`foo -1` vs `foo - 1`, parser.cr:4873-4898). |
| Operators | 7 | Ruby's set as overloadable methods, with overflow checked by default and `&+` to wrap; `===` in `case` (object.cr:248, range.cr:339, regex.cr:567, class.cr:97) is a hidden per-type dispatch a reader cannot see. |
| Type system | 7 | Unions, `Nil` in unions and flow typing make dynamic-looking code statically safe, but global inference means slow builds, no separate compilation, and errors like "can't infer the type of instance variable" (semantic/exception.cr:345) that Ruby users never expected to meet. |
| Object system | 7 | Classes vs structs (reference vs value), modules as mixins (`include Enumerable(B)`, range.cr:60), abstract defs; open classes (json/to_json.cr:1,43,63,93 reopen `Object`, `Int`, `String`, `Array`) and overloads by type restriction cost locality. |
| Grammar | 5 | A 6,621-line hand-written parser full of lexer state (`slash_is_regex!`, `@wants_regex`, `@stop_on_yield`, `do` vs `{}` binding); Ruby's ambiguities are inherited, not dissolved. |
| Concurrency (fibers, `spawn`) | 6 | `spawn do ... end` is lovely, but fibers are unstructured, blocks capture by reference (the documented `55555` surprise, concurrent.cr:96-123), and multi-threaded execution contexts (fiber.cr:104) have no race checking. |
| Channels and `select` | 7 | `select when x = ch.receive` reads well, and `else` gives a non-blocking select; it lowers to an index plus a cast (literal_expander.cr:692-760) by renaming `receive` to a `_select_action` method, a name-convention trick. |
| Macros | 7 | Powerful and AST-typed, with real reflection (`@type.instance_vars`, json/serialization.cr:189), but `{% %}` is a second language, generated methods are invisible to readers and tools, and `system`/`run` execute programs at compile time (macros/methods.cr:70-83, 248, 305). |
| Standard library | 8 | Ruby-rich `Enumerable` (enumerable.cr, 2,350 lines; `tally` at 2021, `group_by` at 654), HTTP, JSON, YAML, spec, all batteries; the eager/lazy split (Enumerable vs Iterator) doubles the API. |

## Area by area (the Ruby lens)

### Blocks, `yield`, procs

The best part of Crystal. A method that `yield`s is always inlined at
its call (semantic/call.cr:446-455: "blocks that yield are always
inlined"), so `each`, `map`, `times`, `File.open do |f|` cost a loop, not
a closure. `break` in a block leaves the yielding call with a value,
`next` gives the block's value, and `return` returns from the
enclosing method (spec/compiler/codegen/block_spec.cr:344-438): exactly
Ruby's semantics, and here zero-cost. The `&.` shorthand
(parser.cr:1603-1626, a block over a temporary `__argN`) gives
`names.map &.upcase`, nicer than Ruby's `&:upcase` because it chains
(`&.name.size`).

Where static types break it: a block that is stored (`&block`) becomes
a heap `Proc` with no inlining, and the language has two worlds.
`Enumerable#map` takes an inlined block and allocates an `Array`
(enumerable.cr:1035); `Iterator#map` captures the block as a `Proc`
inside a `MapIterator` (iterator.cr:921-935), an indirect call per item.
Same word, two costs, chosen by whether `each` was given a block. A
recursive yielder cannot be inlined and is stopped by a nesting limit of
15 (call.cr:450), a heuristic, not a rule.

### Enumerable and iterators

`include Enumerable(T)` plus one `abstract def each(& : T ->)`
(enumerable.cr:43) gives the whole Ruby vocabulary. Iterators use a
`Stop` sentinel (iterator.cr:138, 198) rather than an optional, so every
adapter needs the `wrapped_next` macro to propagate it (iterator.cr:130).
Rig's `next(!@) -> T?` is cleaner, and Rig's chains (SPEC §6, "Chains")
already give eager-or-lazy one cost: a chain is the loop it means.

### Interpolation, ranges, symbols

`"#{x}"` lexes at lexer.cr:1526-1530 and lowers to
`String.interpolation(pieces)` (literal_expander.cr:450-457), which
calls `to_s` and allocates (string.cr:5818-5836). Delightful, but an
allocation no one sees. Heredocs `<<-EOS` strip the closing line's
indentation and reject under-indented lines (parser.cr:2365-2372,
2421): a perfect fit for an indentation language. Ranges keep Ruby's
`..` inclusive and `...` exclusive, Ruby's most-misread pair. Symbols
are compile-time only (no `to_sym` at run time) and autocast to enum
members where an enum is expected (semantic/main_visitor.cr:753):
`paint(:red)`. Rig already has the clean version of both: `.red` from
context and `:name` as a `Symbol`.

### `case`/`when` and `case`/`in`

`case`/`when` keeps Ruby's `===`, plus a gem: an implicit subject,
`when .empty?` or `when .is_a?(Int32)` (parser.cr:3071-3085). `case`/`in`
is the exhaustive form, checked by semantic/exhaustiveness_checker.cr,
which lists the missing types, Bool values, or enum members
(exhaustiveness_checker.cr:51-75). `when _` is rejected with a pointer
to `else` (parser.cr:3086-3091). Two keywords for one idea (`when` and
`in`, exclusive within one case, parser.cr:2888-2898) is a Ruby
compatibility cost. Rig's single exhaustive `match` with guards already
does this better and lists the missing arms (src/typecheck.zig:4517).

### `?` and `!` in method names

The lexer takes a trailing `?` or `!` into the identifier unless `=`
follows (lexer.cr:1143). `?` reads beautifully (`empty?`, `includes?`).
`!` is a convention with three meanings: mutates (`sort!`,
array.cr:1691), raises on nil (`not_nil!`, object.cr:422; `getter!`,
properties.cr:132), and debug-prints the source (`p!`, macros.cr:185).
Nothing checks it. Rig's `!` is a compiler-checked write mark at the
call site, which is strictly better; Rig's DESIGN.md already leaves
`valid?` names behind.

### `property`/`getter`, mixins, open classes

`getter`, `property`, `getter?`, `property!` are macros
(object/properties.cr:11-268). `getter(x) { compute }` memoizes on first
read (properties.cr:31-35): a read that writes. `record Point, x : Int32`
(macros.cr:64), `def_equals_and_hash` (object.cr:658), `delegate`
(object.cr:553), `forward_missing_to` (object.cr:677) all generate
methods. Modules as mixins work as in Ruby. Open classes are fully
supported and the stdlib relies on them (json/to_json.cr reopens core
types to add `to_json`), so where a method comes from depends on what
was `require`d.

### Macros

`{% for %}`, `{{ }}`, `macro inherited/included/finished/method_missing`
hooks (string.cr:155, object.cr:678), AST node types, and reflection
over a type's instance variables and annotations
(json/serialization.cr:189-195). This is how Crystal recovers
`define_method` and `method_missing`. It works; it is also a second
language with its own scoping (`%var` fresh names), and it can run shell
commands at build time.

### Error messages

Good at the leaf ("undefined method 'x' for Nil (compile-time type is
(String | Nil))", semantic/call_error.cr:618; Levenshtein suggestions in
semantic/suggestions.cr), but every error arrives under a stack of
"instantiating 'foo(Int32)'" frames, because inference works per
instantiation. Ruby users find the Nil-union errors the steepest part.

### What Ruby programmers love and hate

Love: blocks and Enumerable intact; speed (often 10-50x Ruby); specs that
read as RSpec; interpolation; one binary.
Hate: compile times that grow with the whole program; no REPL or
`eval`; required annotations on instance variables; nil unions
everywhere; no runtime `send`/`define_method`; long error traces;
macros as the escape hatch for everything dynamic.

## Ideas worth taking for Rig, ranked

### 1. Inlined yield functions: user-written `for` sources (not in Rig)

Crystal:

```crystal
def each_leaf(&)
  stack = [@root]
  while node = stack.pop?
    node.kids.empty? ? yield node : stack.concat(node.kids)
  end
end
tree.each_leaf { |n| return n if n.ok? }
```

Rig today has two ways to walk something: a `for` over a range, array,
List, or an iterator with `next(!@) -> T?`, and chains on those. A tree
walk, a tokenizer, a file's lines, or a grid's neighbours must be
written as an iterator object with its state machine spelled out. A
yield function lets the author write the loop once, as code, and the
caller's `for` body is spliced in where `yield` stands.

Rig form (`yield` is already a reserved word, SYNTAX §3):

```rig pending
obj Tree
  root: ^Node

  fun leaves(?@) yields ?Node
    ...
    yield ?n

fun first_ok(t: ?Tree) -> Int?
  for n in t.leaves()
    if n.ok
      return n.id
  none
```

Guarantees: it is a `for` loop, so the body is not a closure: no
captures, no allocation, no capture list to write, and `break`,
`continue`, and `return` are the caller's, as in any `for`. Accept
means correct holds if the checker checks the spliced loop, as it
already checks a chain as "the loop it means". A yielded view lives for
one iteration (the yielder's state stays lent while the body runs), so
it fits CORE as a `for` over an iterator whose items are views. Two
rules Crystal does not have and Rig would need: a yield function that
recurses, directly or through another, is rejected with a Rig diagnostic
(Crystal's depth limit of 15 is not a rule); and a `break` or `return`
out of the body runs the yielder's `defer`s and drops in order, which
must be a recorded fact so emit decides nothing. This touches ownership
(views across the splice), so CORE gets its paragraph first.

### 2. Compile-time fields: `$fields(T)` (not in Rig)

Crystal: `{% for ivar in @type.instance_vars %}` in
json/serialization.cr:189 gives `JSON::Serializable`, YAML, and DB
mapping as library code.

Rig has `$size`, `$align`, `$name`, `$variants(T)` (a run-time array of
a plain enum's values), compile-time functions, and derived `Eq`,
`Hash`, `Print`, `Ord` by the fields (SPEC §3 "Own meanings"), but no
way for library code to walk an object's fields. Rig form, unrolled
once per field and checked per instance as Zig's `inline for` over
`@typeInfo` is:

```rig pending
fun decode[T](p: !json.Parser) -> T!
  out = T()
  for f in $fields(T)
    if p.key() == f.name
      @(out, f) = p.value[f.type]()!
  out
```

The exact form for "the field named by `f`" is a naming question for
the owner. Guarantees: no macros and no generated hidden names; every
unrolled body is ordinary checked Rig, so accept means correct and
effects stay visible; no allocation beyond what the body writes. It is
what std.json's typed decode and a user's own `Print` need. Fields that
are views or handles must report their kind so a body cannot copy an
owner silently.

### 3. Indented text blocks (not in Rig)

Crystal heredoc `<<-EOS` strips the closing line's indentation and
rejects a line indented less (parser.cr:2365-2372). Rig strings may hold
no newline (SYNTAX §4), so help text, SQL, and test fixtures are
`"line\n"` runs. Rig's own test files already use `'''` for a result of
several lines, so the form exists in the project's eye:

```rig pending
usage = '''
  usage: tool [-h] FILE
    -h  print this
  '''
```

The indentation of the closing `'''` is removed from each line, as
Crystal does; the value is `Static` text, so no allocation and no
ownership question.

### 4. A debug print that shows its source: `dbg(e)` (not in Rig)

Crystal `p! a + b` prints `a + b # => 3` (macros.cr:185; `pp!` at 151).
Rig form: a builtin `dbg(a + b)` that writes `f.rig:12: a + b = 3` to
standard error and gives its value. It reads its argument as `print`
does (unmarked read), so no hidden effect beyond the write it names. It
shares a mechanism with the approved "assert with values", so they
should be one feature with one rendering of source text and values.

### 5. A select arm for "none ready" (not in Rig)

Crystal `select ... else` becomes `Channel.non_blocking_select`
(literal_expander.cr:692-760). Rig's `task.select` waits for one arm
and has no try-receive form. Rig form, an arm that wins only when no
other arm is ready at once (the word is the owner's call):

```rig pending
match task.select(got: !ch.on_recv(), idle: task.ready_none())!
  .got(v?) => use(v)
  .idle => do_other_work()
```

It keeps Rig's named, typed variants and `match` checking, so nothing
of the design changes. `time.after(ms: 0)` is not the same, since a
deadline races fairly with ready arms.

### Smaller notes

- `when .empty?` (parser.cr:3071) is lovely, but Rig's `.name` already
  means an enum variant, and a guard (`s if s.is_empty() =>`) covers it.
- Unbuffered (rendezvous) channels are Crystal's default
  (channel.cr:83, `@capacity = 0`); Rig requires at least one slot.
  Worth a look only if a program needs a handoff that waits for the
  receiver.

## What Rig should not take

- **Interpolation as Crystal does it.** `"#{x}"` allocates a String
  through `to_s` (literal_expander.cr:450, string.cr:5834): hidden
  allocation. Rig's `String(a, b)` and `print(a, b)` say it.
- **`?` and `!` in names.** Convention, unchecked, with three meanings
  for `!` (array.cr:1691, object.cr:422, macros.cr:185). Rig's call-site
  `!` is checked; a second `!` in names would fight it.
- **`&.` shorthand.** `.name` is taken by enum variants, and `|x| x.len`
  is already short; a second closure syntax breaks "one mechanism".
- **Two block worlds** (inlined `yield` vs captured `Proc` with the same
  method names, enumerable.cr:1035 vs iterator.cr:921). Rig's chains
  already give one cost; idea 1 should stay a `for` source, never a
  value.
- **Macros** (`{% %}`, hooks, `system`/`run` at compile time). Rig's
  DESIGN.md lists macros as a non-goal; typed compile-time functions
  plus `$fields` cover the real uses (serialization, derives).
- **`property`/`getter` macros, and the memoizing `getter { }`** (a read
  that writes, properties.cr:31-35). Rig fields are read directly and
  writes are marked.
- **Open classes** (json/to_json.cr). Rig's `add Int: Shape` only in
  `Shape`'s module keeps where a method lives knowable.
- **Overloads by type restriction and multiple dispatch.** One name, one
  meaning, one place.
- **`===` in `case`.** A hidden per-type dispatch; Rig's patterns are
  structural and visible.
- **`..` inclusive / `...` exclusive.** Ruby's most-misread pair; Rig's
  `..` / `..=` is right. Note for Ruby users that Rig's `..` means
  Ruby's `...`.
- **`when` and `in` as two keywords for one `case`.** Rig's one `match`
  is always exhaustive.
- **Whole-program inference.** It is the source of Crystal's slow builds
  and instantiation-trace errors; Rig's declared signatures keep
  `rig check` fast and errors local.
- **Unstructured `spawn` with by-reference capture** (concurrent.cr:96-123,
  the `55555` example). Rig's `f(x)&` with capture sigils and `>t`
  dissolves that bug.
- **A GC, exceptions, and runtime `Nil` unions.** Against Rig's North
  Star; `T?`, `T!`, and `if o as x` already cover them.
