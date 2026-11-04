# Rust panelist: select spelling

**A: prefer.** Rust names a variant bare where it is *declared* (`enum R { Add(i32) }`) and qualifies it where it is *used* (`R::Add(v)`). A struct literal uses plain `field: value`. In A the call's keyword arguments declare the variants, and the arms use them as `.add`. That is Rust's split, and Rig's own (an object field is declared `x: Int` and read `.x`). Every call still writes `name: value`, so nothing new is learned, and the grammar needs no change.

**B: avoid.** A leading dot in Rig *refers to* an existing variant, inferred from context. Here it would *declare* one. That gives one mark two meanings, and it breaks "every call writes `name: value`". Zig's `.{ .add = x }` puts a dot on fields, but Zig is consistent about it everywhere. Rig is not, so B would be the one call that looks different.

**C: avoid.** `=>` means "when this matches, run this", with the pattern on the left and the effect on the right. In C the direction is reversed: the operation on the right *produces* the tag on the left. Readers and AIs would parse it as a nested match. It is punctuation doing a keyword's job.

**Pick: A.** I have no fourth spelling that beats it.
