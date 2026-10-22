# Rig syntax options: guards, conditionals, and how much freedom

A record of the owner's syntax discussion of 2026-10-11, started by one
function in the JSON parser (Trig's then; Rig's `std/json.rig` since). **Decision: change nothing in Rig's
syntax for now.** Today's forms are coherent, and every option below is
additive, so any of them can be adopted later without breaking code.

## 1. Where it started

`document` in the JSON parser, as it was written then:

```rig
fun document(!self, src: ?String) -> Int
  n = src.len
  return (!self).fail(.too_large, 0) if n > MAX_INPUT
  i = skip_space(src, 0)
  return (!self).fail(.empty, i) if i == n
  while true
    # A value starts at `i`.
    return (!self).fail(.eof, i) if i >= n
    c = src[i]
    if c == LBRACE or c == LBRACKET
      return -1 if (!self).open(c, i) < 0
      ...
```

The owner proposed three ways to tighten the guards:

| | Form |
|---|---|
| A | `return (!self).fail(.empty, i) if (i = skip_space(src, 0)) == n`, with `if (c = src[i]) in [LBRACE, LBRACKET]` |
| B | `(i = skip_space(src, 0)) == n then return (!self).fail(.empty, i)` |
| C | `(i = skip_space(src, 0)) == n and return (!self).fail(.empty, i)` |

## 2. The panel

A language designer, a pragmatist, a Ruby programmer and a minimalist
each rewrote the whole function independently. They agreed on nearly
everything.

**The guard shape was not the noise.** The noise came from four other
things:

1. the `-1` sentinel protocol (`return -1 if … < 0`, a final `-1`);
2. `(!self).fail(...)` on every exit;
3. byte constants (`LBRACE`) in place of characters;
4. `self.stack[self.stack.len - 1]`.

**Rig today already removes the first of these.** A fallible function
(`sub document(!self, src)!`) with `!` propagation turns every
`return -1 if (!self).open(c, i) < 0` into `!self.open(c, i)!`. Two
panelists ran this version: same errors and positions, sanitizer-clean.

**Token counts (minimalist):**

| Version | Tokens |
|---|---:|
| Today | 343 |
| A, B or C | 350 (more: each `(x = e)` adds parentheses) |
| Today's language, fallible functions | 311 |
| Plus the three root fixes (errors with data, byte literals, `last()`) | 267 |

**Verdicts** (every panelist agreed unless noted):

| Idea | Verdict | Why |
|---|---|---|
| A: assignment inside a condition | reject | a use is read before its definition; the `=`/`==` slip; the name leaks out of the condition; `if v as x` already binds safely |
| B: `cond then action` | reject *as an addition* | a second spelling of the guard (see section 4: adopted as a replacement, it is coherent) |
| C: `cond and action` | reject | Ruby's own linter bans it; works only when the action returns `Bool` (section 6) |
| Rip-style `then`/`else` as low-precedence `&&`/`\|\|` | reject | `c then a else b` = `(c && a) \|\| b` runs `b` when `a` is false |
| Dropping call parentheses (`fail .eof at i`) | reject | "a name alone never runs code"; `f <x` becomes move-or-less-than |
| Keep `return x if c` | keep | the Ruby statement modifier, already in Rig |
| Fallible functions with `!` | adopt now | no language change |
| Errors that carry data | adopt | the biggest single cut; on Rig's roadmap (IDEAS 1.4) |
| `'{'` as a `U8` where a `U8` is expected | adopt | `'{'` already lexes; `c == '{'` is rejected today, so no program changes meaning |
| `list.last() -> T?` | adopt | std, not syntax; reject `xs[-1]` |
| `x in [a, b]` / `c in "{["` | maybe later | literal list or range only, so it is never a hidden loop |

**Child, teenager, older person.**

- A child says "If it's too big, stop!": one action per sentence, and
  never naming a thing in the middle of a question.
- A teenager says "Too big? Bail.": shorthand that leans on tone of
  voice text doesn't carry.
- An older person says "Report an unexpected end, and where.": the
  failure named by its meaning, which is `return Json.eof(i)`, not
  `return -1`.

**The weight of a guard is in its action, not in where the condition
sits.**

## 3. What Rig has today (verified with the compiler)

- **Block `if`.** The condition first, the body indented, then `else`.
- **Statement modifier.** A simple statement (a call, a binding or
  assignment, a drop, `return`, `break`, `continue`) may end with
  `if cond`.
- **Ternary** in Python order: `a if c else b`. Statements work too:
  `print("yes") if c else print("no")` runs.
- **Binding in a condition:** `if a as x`, `while a as x`, and chains
  such as `if a as x and x > 0 and b as y`.
- **Fallbacks:** `a ?? b` and `a ?? return v` for optionals;
  `e catch f`, `e catch return v` and `catch |e|` for errors.
- **Propagation:** `f()!` and `x?`.
- **A function returns its last expression.** An `if`/`else` block is a
  value: `fun grade(n: Int) -> Int` ending in `if n > 90` / `1` /
  `else` / `2` works.
- **A block `if` and a modifier parse to the same tree:**
  ```
  if found              (if found (block (call note 7)) _)
    note(7)
  note(7) if found      (if found (block (call note 7)) _)
  x = 1 if found else 2 (set _ x _ (if found 1 2))
  found and note(7)     (and found (call note 7))
  ```

## 4. Three consistent designs

With `else` included:

**Design 1: action first (Rig today).**
```rig
if c
  action
else
  another

action if c else another
action if c
```

**Design 2: condition first, no `if`.** This is C's `c ? a : b` in
words; Rig can't use `?` and `:`, since `?` is a sigil.
```rig
c then action else another
c then action
```

**Design 3: `if` always first; `then` folds a block onto one line.**
```rig
if c then action else another
if c then action
x = if c then a else b
```

**The same guard in each:**

| Design 1 | Design 2 | Design 3 |
|---|---|---|
| `return Json.eof(i) if i >= n` | `i >= n then return Json.eof(i)` | `if i >= n then return Json.eof(i)` |

**`a if c else b` and `if c then a else b` mean the same thing.** They
differ only in word order: Python against Haskell, OCaml and Ruby.
Design 2 is the C order, `c ? a : b`.

**Hidden control flow, in Andrew Kelley's sense: none of them has
it.** Each branch is marked by a keyword where it happens, as Zig's own
`orelse`, `catch` and `try` are. What differs is *when* the reader
learns a line is conditional:

| Design | The reader learns the line is conditional |
|---|---|
| 1 | at the `if`, after an action that looked unconditional |
| 2 | at the `then`, after what looked like a plain expression |
| 3 | at the first word (Zig's own `if (c) a else b`) |

**Design 3's rule:**

> Every branch on a `Bool` starts with `if`; `then` puts the body on the
> same line, a line break and indent put it below.

It needs two refinements:

- `if x else another` is consistent, but prefer `if not x then another`.
- A dangling `else` in nested one-liners
  (`if a then if b then x else y`) needs a rule. The simplest is that a
  one-line `then` body cannot itself be a one-line `if`.

## 5. Every conditional in Rig

**Under Design 3, every branch on a `Bool` starts with `if`.** The other
conditionals each have their own keyword, as in Zig:

| Form | Decides on | Zig |
|---|---|---|
| `while c`, `while a as x` | a repeated `Bool`, or a value being present | `while` |
| `a and b`, `a or b` | `Bool` operators that skip `b` when the answer is known | `and`, `or` |
| `match v` | a pattern | `switch` |
| `a ?? b`, `if a as x` | an optional | `orelse`, `if (a) \|x\|` |
| `e catch f`, `f()!`, `x?` | an error or `none` | `catch`, `try` |
| loop `else` | the loop ending without `break` | `while … else` |

The one postfix `if` left would be the match guard, `k if k < 0 =>`. The
option is to write it `k when k < 0 =>`. `when` is a reserved word in
Rig's grammar that no form uses yet, so this would be its only use.

The loop `else` is a known surprise (as Python's `for … else` is) and is
worth a separate look.

## 6. `and` implies a `Bool`

- `found and note(7)` compiles only when `note` returns `Bool`.
  `found and note2(8)`, where `note2` is a `sub`, fails with
  "expected `Bool`, got `Void`". So whether the line is legal depends
  on the action's return type, not on what was meant.
- `ok and 3 > 2` is a value, "are both true?", and is never "no value".
  `and` is a `then` with a hidden `else false`:
  `ok and 3 > 2` = `if ok then 3 > 2 else false`.
- `ok then 3 > 2` is an action: when `ok` is false nothing happens and
  there is no value.
- **The rule:** an `if`/`then` without `else` is a statement; used as a
  value it needs an `else` (as in Rust and Zig).
- `not note(7) else found`, with `else` as `||`, runs `note(7)` every
  time. The form that means "note only when found" is
  `not found else note(7)`, a double negative. This is the trap the
  panel warned about: the natural reading and the real meaning differ.

## 7. The one-node rule

> Each meaning has one node. Every way of writing it is surface syntax
> that builds that node.

**What it buys:**

- Extra phrasings cost only grammar. The type checker, the ownership
  checker and the emitter see one form, so no soundness risk is added.
  This matches Rig's rule that a feature is specified as a desugaring.
- The forms cannot drift apart, since they are the same node.
- It gives a mechanical test for traps: a spelling that parses to
  something other than what it reads as (`not note(7) else found` →
  `(or (not …) found)`) is an error with a hint.

## 8. How much freedom: TIOOWTDI or TIMTOWTDI

- **Strict** (Zig, Go): one form, and every other form is an error with a
  hint. Uniform, but perfectly clear code is refused.
- **Permissive** (Ruby, CoffeeScript, Rip): say it the way it comes out.
  Expressive, but readers must know more forms.

**The middle path discussed:**

> Each meaning has one node, and each effect one marking. A meaning may
> be phrased in a small, closed set of forms, each unambiguous and
> familiar from a major language. A form whose reading differs from its
> meaning is an error that names the right form. A formatter
> (`rig fmt`) can impose a house style for teams.

| Meaning | Phrasings | Rejected (traps) |
|---|---|---|
| Do x only if c | `if c` block, `if c then x`, `x if c` (simple statements) | `c and x()`; `c then x` as `&&` |
| Do x unless c | `if not c …`, `x unless c` | `not x else c` |
| Choose a value | `if c then a else b`, `a if c else b` | |
| Bind if present | `if v as x` | `(x = v) && …` |
| Fallback | `?? v` (tight), `catch` (loose) | `or` on truthiness |
| Effects | exactly one marking each | anything that hides them |

**From the owner's own Ruby:** the clear lines say one idea each, and
the unclear ones pack several into one form. For example:

- an assignment that changes a variable's type mid-line;
- a nested ternary that returns a list or a string;
- a trailing `if` after a seven-line block.

Freedom of phrasing is fine; packing several thoughts into one form is
where readers stumble.

## 9. Symbols bind tight, words bind loose

The Perl and Ruby principle behind `a && b && user or signout!`.

- **Rig already follows it in part:** `??` (a symbol) binds above
  comparisons, and `catch` (a word) sits at the lowest level.
- **Applied fully:**
  - `&&`, `||` and `??` would be tight;
  - a loose `or` would mean "or else" when the left side produces no
    value (`none`, a failure, or `false`);
  - `catch` would handle errors.
- **The catch:** Rig has no truthiness, so `a && b && user` can't return
  `user`. The typed forms are `if a and b then user else signout()` and
  `parent_user() ?? signout()`.
- **Costs:**
  - `&&`/`||` would duplicate `and`/`or` unless the words change
    meaning;
  - a loose `or` over three kinds of failure hides which one is meant
    (Zig keeps `orelse` and `catch` apart);
  - `||` may collide with an empty closure parameter list.

## 10. `as`

`if foo() as x` binds a name, as `x = foo()` does. It also:

- **tests** whether there is a value;
- **unwraps** `T?` to `T`;
- **scopes** the name to the `if` or `while`;
- **can lend instead of copy:** `?a as x`, `!a as x`, `<p.f as x`.

It is Ruby's `(x = foo()) && …` made safe. `if user() as u and
u.is_parent()` replaces truthiness, and that is the main habit a Ruby
programmer unlearns in Rig.
[RUBY-IDIOMS.md](RUBY-IDIOMS.md) writes ten of the owner's Ruby snippets
in Rig this way.

## 11. The function, in the form discussed

Not adopted. Marked: [T] `if … then`, [E] errors with data, [B] byte
literals, [L] `last()`. Fallible functions, `!` and the labeled
`?? break` work today.

```rig
# Parses the one value `src` holds, with whitespace around it.
sub document(!self, src: ?String)!
  n = src.len
  if n > MAX_INPUT then return Json.too_large(0)
  i = skip_space(src, 0)
  if i == n then return Json.empty(i)
  :doc while true
    # A value starts at `i`.
    if i >= n then return Json.eof(i)
    c = src[i]
    if c == '{' or c == '['
      !self.open(c, i)!
      i = skip_space(src, i + 1)
      if i < n and src[i] == c + 2          # `{}` or `[]`
        !self.close()
        i += 1
      else
        if c == '{' then i = (!self).key(src, i)!
        continue
    else
      i = (!self).scalar(src, i, c)!
    # A value ended before `i`: a comma or a close comes next.
    while true
      i = skip_space(src, i)
      top = self.stack.last() ?? break :doc
      if i >= n then return Json.eof(i)
      in_object = top & 1 == 1
      if src[i] == ','
        i = skip_space(src, i + 1)
        if in_object then i = (!self).key(src, i)!
        break
      closer = if in_object then '}' else ']'
      if src[i] != closer then return Json.unexpected(i)
      !self.close()
      i += 1
  if i < n then return Json.trailing(i)
```

**Tighter still,** with membership (`c in "{["`) and comparing an
optional to a value (`src.get(i) == c + 2`, where `none` never equals a
byte):

```rig
    if c in "{["
      !self.open(c, i)!
      i = skip_space(src, i + 1)
      if src.get(i) == c + 2          # `{}` or `[]`
```

## 12. Decision

- **Rig's syntax:** unchanged for now; adjust with experience. The
  deferred ideas are listed in [README.md](README.md).
- **The parser's error plumbing** (fallible functions with `!` in place
  of `-1` sentinels) moved with the parser to Rig's `std.json`, where
  Rig's std conventions decide it.
