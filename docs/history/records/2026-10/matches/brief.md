# Iterator panel brief (2026-11-02)

## The task (Rust)
```rust
fn trim(&mut self) {
    while self.entries.len() > MAX_ENTRIES || self.bytes > MAX_CACHE_BYTES {
        let oldest = self.entries.iter()
            .filter(|(_, entry)| matches!(entry.state, State::Ready(_)))
            .min_by_key(|(_, entry)| entry.touched)
            .map(|(key, _)| key.clone());
        let Some(key) = oldest else { break };
        let entry = self.entries.remove(&key).unwrap();
        self.bytes -= entry.bytes;
        if let State::Ready(Some(rendered)) = entry.state {
            self.retired.push(rendered.image.clone());
        }
    }
}
```

## Rig today (compiles and runs on Rig main, sanitizer-clean)
```rig
sub trim(!@)
  while @entries.len > MAX_ENTRIES or @bytes > MAX_CACHE_BYTES
    oldest: String? = none
    touched = 0
    for e in ?@entries.items()
      if e.value.state as .ready(_)
        if oldest == none or e.value.touched < touched
          oldest = +e.key
          touched = e.value.touched
    key = <oldest ?? break
    entry = !@entries.take(key) ?? break
    @bytes -= entry.bytes
    if entry.state as .ready(r) and r as rendered
      !@retired.push(+rendered.image)
```
Types: `enum State` with `loading`, `ready(rendered: Rendered?)`; `obj Entry` with `state`, `touched: Int`, `bytes: Int`; `obj Cache` with `entries: Map[String, Entry]`, `bytes: Int`, `retired: List[Image]`.

## Rig facts you must design within
- Indentation-sensitive; compiles to Zig; no GC, no hidden allocation, no hidden refcount, no silent control flow. Speed is the owner's first priority (the race is against Rust's tsrs), so any feature must cost nothing at run time (inline, no allocation, no boxed closures).
- Sigils mean the same everywhere: `?x` lend to read, `!x` lend to write (marked at the call: `!m.put(k, v)`), `<x` move, `+x` clone, `@` self (`@entries` a field of self), `x?` / `x ?? d` optionals, `e!` failure. Reading is unmarked; writing is marked.
- Brackets after a name are compile time (`List[Int]`), parentheses run time.
- Closures exist: `|x| x + n`, with capture marks `|+n, x|`, `|?n, x|`, `|!n, x|`; `?fun(Int) -> Int` is a view of a closure. Closure calls in generic bodies are direct and inlinable.
- Iterators exist: a type with `next(!@) -> T?` provides the built-in API `Iter`; `for x in it` walks it. `?m.items()` on a Map gives items `e.key: ?K`, `e.value: ?V` that view the map (keep it lent to read). std.iter has only `count` and `sum`. There are NO adaptors today (no filter, map, min_by, find, any).
- Patterns: `if x as .ready(r)` tests and binds; `x as .ready(_)` tests. There is no `is` / `matches!` expression form outside `if`/`while` conditions.
- Optional chaining: `o ?? d`, `if o as x`; there is no `?.map(...)` on optionals.
- Owner's taste: short plain words (three letters where they read well: `obj`, `sub`, `fun`); a mark for a mechanic, a word for a library; a word people already know used for what it already means; no punctuation doing a keyword's job; one word and one mechanism per idea; clean, consistent, least-surprise syntax; ideal for AIs to write.

## Your answer (≤400 words to report, full version in your file)
1. Your "dream" Rig version of `trim`, as your language's best idiom would inspire it, but in Rig's syntax and sigils.
2. Exactly which features it needs, each one line: library (std adaptors) or language (new syntax).
3. Would adding iterator adaptors alone get most of the way? What is the gap?
4. Ownership traps: the chain yields views of the map; the key must be cloned or moved out before `take` writes the map. How does your version make that visible and correct?
5. Zero-cost: how does it compile to the same loop as the hand-written one?
