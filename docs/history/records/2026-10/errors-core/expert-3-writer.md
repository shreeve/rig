# Expert 3 (writer): "A failure moves its error"

## 1. The paragraph

**A failure moves its error.** An error set's member may carry fields,
as an enum's variant does. Each field's type holds no loan, holds no
handle (`*`, `~`), and clones (sentence 2), so an error never keeps an
owner lent, goes to any task, clones with `+e`, and runs no `drop` body
when it drops. *(planned)* An error is plain or owning by the enum rule
(§1), and `error`, which holds an error of any set, is owning. *(built)*
Each call of a fallible function is lent a hidden write view of its
slot, an optional the caller owns, and keeps no parameter there
(sentence 7). A failing `return E.name(...)` moves the error into the
slot before the function's defers and drops run; `e!` lends its call
the slot the function itself was lent, so the same error goes on up;
`catch |err|` takes it out (`err = <slot`) as the handler's own
binding, which drops when the handler ends unless the handler moves it
on (`return err`, `<err`); and a `catch` that binds no name, or `_`,
drops it before its handler runs (`<slot`). A call started as a task
(`t = f()&`) is lent a slot its `Task` owns: `>t!` and `>t catch` take
the error from `t` as they wait on it, and dropping `t` drops it.
*(built:* the moves of `return`, `e!`, and `catch |err|`; *planned:*
the slot, a task's slot, and a nameless `catch` dropping first.*)*
Reading, matching, printing, storing, and cloning an error follow its
type, as for any value. *(built)*

## 2. Examples

- **Keep** the `rig reject` example (`use of `err` after move`): built,
  and it shows the handler owning `err`.
- **Keep** the `rig pending` example. It already shows a nameless
  `catch` (`twice("42") catch -1`), `e!`, `catch |err|`, and a `match`
  on fields.
- **Add** one `rig pending` rejection for the field rule, the new fact
  a reader most needs to see (it passes today: rejected with other
  messages):

```rig pending
error ParseError
  bad(src: ?String)

sub main()
  pass
```

```error
an error's field never holds a loan: hold a `String` or a `Static`
```

## 3. Decisions for the owner

1. **Marks:** one mixed mark after the slot sentences, as sentence 1
   does, rather than splitting each sentence into a built half and a
   planned half (which repeats every move twice). [mixed mark]
2. **The word "slot":** §5 already uses it for a `Table`'s element.
   Both are a place that holds one value, so it is one idea, not two.
   [keep "slot", defined here as "an optional the caller owns"]
3. **The field-rule example** above. [add it]
4. **Tasks in CORE:** this is the first place CORE names `&` and `>t`.
   Gloss them inline (`t = f()&`, "as they wait on it") rather than add
   a tasks section. [inline gloss]

## 4. Reasoning (≤300 words)

What I changed from the §9 draft, and why:

- **Split the field sentence.** The draft put four consequences in one
  "so" clause with shifting subjects ("`+e` always works"). Now one
  subject, four verbs: keeps no owner lent, goes to any task, clones,
  runs no `drop` body. "Goes to any task" is CORE's own phrase (§7).
- **Untangled the slot sentence.** "is lent, hidden, a write view of a
  slot of its caller's, which keeps nothing" has a double possessive
  and an unclear "which". Now: "lent a hidden write view of its slot,
  an optional the caller owns, and keeps no parameter there". Naming it
  an optional makes the desugaring visible: `catch |err|` is
  `err = <slot`, a nameless `catch` is `<slot` (§5's `<` of an optional
  place). That is CORE §10's test, shown, not asserted.
- **"Before the scope's exits run"** became "before the function's
  defers and drops run": CORE says "defer" and "drop"; "exits" is
  compiler language (§9).
- **Honest marks.** The draft had none. The moves are built; the slot,
  the task slot, and the nameless catch are planned.
- **Kept "as for any value"** from today's text: it tells the reader
  nothing special happens.

What may be wrong in the draft (and kept, softened, here):
"keeps nothing (sentence 7)" holds for a named function, whose
signature names no `keeps`. For a function value, sentence 7 says
nothing narrows its stores, so the no-`keeps` argument does not apply;
there the field rule ("holds no loan") carries the guarantee, as the
spec's §10 admits. The paragraph stays true because both sentences are
in it, but the oracle cannot derive the closure case from sentence 7
alone.
