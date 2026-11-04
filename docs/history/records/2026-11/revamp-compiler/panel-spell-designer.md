# Select spelling: designer's verdict

**A: prefer.** It is an ordinary call written the ordinary way, so nothing new has to be learned or parsed. Swift users see the label-to-case link at once, because a Swift case is declared much like a labeled argument (`case add(Int)`). Beginners and AIs will write A without being taught it, since it is how every Rig call looks. The link between `add:` and `.add` is one sentence in SPEC and one hover in the LSP.

**B: avoid.** A leading dot means "a variant of a type that already exists". Here `.add:` would *create* the variant, so the one mark gets a second meaning. It also adds a second keyword-argument syntax that is valid in exactly one call. Zig readers would take `.add` as a field, as in `.{ .add = x }`, and that is a third reading. AIs will spread `.name:` to other calls.

**C: avoid.** `=>` means "when this matches, run this". Inside the call it would mean "this name comes from this source", which reads backwards. The same mark, a few lines apart, would point in opposite directions. AIs and skimming readers will mistake the call's lines for match arms and put bodies there. It also risks the grammar's LALR(1) cleanliness for nothing.

**No fourth spelling beats A.**

**Pick: A.**
