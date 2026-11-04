# Zig expert: spelling the select arms

**A: prefer.** Zig's lesson is that one spelling for "name = value" goes everywhere. Zig writes `.{ .add = x }` for every struct literal and every union literal alike, and never makes an exception for one function. In Rig, the uniform spelling is `name: value`, so a select's arms should be written as ordinary keyword arguments. The compiler builds the result's variants from those names, much as Zig builds an anonymous union's tags from the field names in `.{ .add = x }`. The user learns nothing new, and the parser needs no new rule.

**B: avoid.** B looks like Zig, but it borrows only Zig's dot, not Zig's consistency. In Zig, every field name in a literal has the dot. In Rig, only select's arguments would. It would also give `.add` a second meaning. Today `.east` names a variant of a type that already exists; here `.add` would create a new one. That is two meanings for one mark.

**C: avoid.** In Rig, `=>` means "when this pattern matches, run this", and it appears only in `match` arms. In C, `.add => !a.on_recv()` would mean "name this operation `add`". The direction and the meaning are reversed, and it puts `=>` inside a call, outside any `match`.

**Pick: A.** I have no fourth spelling that beats it.
