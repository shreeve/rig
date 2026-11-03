# Iterator panel: summary (Swiss, 2026-11-02)

All three experts (Rust, Ruby, Swift) wrote the same Rig, independently; it parses today:

    sub trim(!@)
      while @entries.len > MAX_ENTRIES or @bytes > MAX_CACHE_BYTES
        oldest = ?@entries.items()
          .filter(|e| e.value.state as .ready(_))
          .min_by(|e| e.value.touched) ?? break
        key = +oldest.key
        entry = !@entries.take(key) ?? break
        @bytes -= entry.bytes
        if <entry.state as .ready(r) and <r as rendered
          !@retired.push(<rendered.image)

Rig already has an approved design for this: docs/design/iterators.md (fused chains, approved
2026-10-27, not built). A chain is rewritten into the `for` loop it means before the checkers, so it
costs what the loop costs and needs no closure fields (the experts' biggest gap for adapter objects).

Missing from the approved design, needed for `trim`:
1. `min_by(key)` / `max_by(key)` consumers (the design has only `min()`/`max()`, which need Ord items).
2. `x as .pattern` with no bound names as a Bool anywhere (checker only; already parses).
3. A consumer's result that views the source keeps it lent while it lives (as `?m.get` does).

Ownership: the checker already rejects `take(oldest.key)` (read loan live) and `take(+oldest.key)`;
`key = +oldest.key` is the visible clone and ends the loan. The chain clones once per eviction; the
hand loop clones on every new minimum. The image can move (`<rendered.image`) instead of cloning.

Reports: rust.md, ruby.md, swift.md (+ rust-proto.rig).
