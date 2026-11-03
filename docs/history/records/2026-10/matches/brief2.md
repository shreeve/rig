# Panel round 2: the one-armed match (2026-11-02)

## What it does, in one sentence (Swiss's narration)
"If the entry we just removed was ready and holds a rendered result, move that result's image onto
the retired list."

## Rig today: the full match (compiles and runs on Rig main, sanitizer-clean)
```rig
match <entry.state
  .ready(r)
    if <r as rendered
      !@retired.push(<rendered.image)
  _ => pass
```
`entry` is owned (just taken out of the map). `state: State`, `enum State` with `loading` and
`ready(rendered: Rendered?)`. `obj Rendered` has `image: Image`. `<x` moves x; without the `<`
marks the parts are only viewed and the image must be cloned (`+rendered.image`). Rust's equivalent:
`if let State::Ready(Some(rendered)) = entry.state { self.retired.push(rendered.image) }`.

## Rig today: the one-arm forms (both compile)
```rig
if <entry.state as .ready(r) and <r as rendered
  !@retired.push(<rendered.image)
```
```rig
if entry.state as .ready(r) and r as rendered
  !@retired.push(+rendered.image)
```
`if X as PATTERN` is Rig's one-armed match (Rust's `if let`, Swift's `if case`). `as` also unwraps an
optional: `if o as x`. Patterns: `.name`, `.name(a, b)`, `.name(f: a)`, `_`, literals, ranges,
alternatives `p, q`, guard `p if cond` (SYNTAX.md §12). There is NO nested pattern today (no
`.ready(rendered?)`, no `.ready(some(x))`); optionals are only unwrapped by `as` or `??`.

## The owner's reaction
The `as` form is confusing to him ("I don't understand this syntax"). He asks: should the one-liner
still use the word `match`, in a form much closer to the full match? Can it be cleaned up? He finds
the full `match` normal. Swiss proposed `is` for pattern tests (`if state is .ready(r)`), keeping
`as` for optionals; the owner hasn't chosen.

## Constraints (unchanged from round 1's brief.md)
Zero cost; ownership visible (`<` move, `+` clone, `?` view, `!` write); one word and one mechanism
per idea; short plain words people already know, used for what they mean; no punctuation doing a
keyword's job; indentation-sensitive, no braces; clean, consistent, least surprise; ideal for AIs.
Any change must keep the full `match` working and should make the one-arm form read as the same idea.

## Answer (≤350 words to report; full version in your file)
1. The ideal one-arm spelling of this exact code, in Rig, with your reasoning. Must it say `match`?
2. The ideal way to write Swiss's one-sentence narration, as Rig code (any number of lines).
3. Does it need nested patterns (`.ready(rendered?)` or similar)? Is that worth adding? Show the
   pattern grammar change in one line.
4. Where should the moves (`<`) go, so they are visible but not noisy? (One `<` on the subject?)
5. What does `as` become: kept, renamed, or removed? One recommendation.
