Rig 0.1.5 is a patch release. It fixes memory-safety holes in 0.1.4 involving method receivers: `rig check` accepted programs that then read freed or dead memory, or lost a change. That breaks Rig's promise that safe code cannot corrupt memory. **Everyone on 0.1.4 or earlier should upgrade.**

## Fixed

- **A view returned from a method called on a branching value.** The view carried no loan on either branch, so this program read freed memory:

  ```rig
  r = (a if c else b).inner()   # a `?self` method returning a view
  a.t = Text("zz")              # frees what r views
  print(r)
  ```

  The same hole appeared through a field or element base, `??`, `catch`, and `o?`. Such a call is now rejected. The message suggests lending each branch, `(?a if c else ?b).inner()`, which works and keeps both branches lent.
- **A view of a temporary receiver used past its statement.** Examples: `r = mk().arr()`, or `!mk(42).at()` as a function's last value. The view pointed into a temporary that had already ended. It is now rejected in every position the view could leave its statement:
  - a binding;
  - a function's or closure's last value, and `return`;
  - an `if` or `match` arm;
  - a `break` value.

  A view used within its statement still works.
- **A receiver stored into a write argument.** A method that stores a view of its receiver in a write argument (`s.put(!h)`, where `put` stores `?self.items[..]` in `h`) left the receiver unlent, so `-s` freed what `h` viewed. The receiver is now lent like any other argument. This covers `?self`, `!self` and moved receivers, and fields, elements, handles and temporaries.
- **A change to a branching receiver.** A method that changes its receiver, called on a branching value (`(h1 if c else h2).q.bump()`), changed a copy, so the change was lost. With a `!self` method on a plain struct, the generated Zig failed to compile. These calls are now rejected, with the hint to lend each branch: `(?h1 if c else ?h2).q.bump()`.
- **A temporary receiver freed twice.** A temporary receiver used for a call whose arguments run first (`mk("a").pick(y: f(1), x: f(2))`) was copied out of its slot and freed twice. A branching receiver of such a call was freed by the call too. Both now run correctly.

Every program 0.1.4 accepted that has none of these shapes compiles to the same behaviour.

## Verification

- **New tests:** reject tests for every form above, each accepted by 0.1.4. Behavior tests with a stack clobber for the forms that keep working. Matrix cells for receiver views.
- **Gates:** the full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator. CI passed on Linux and macOS.
- **Equivalence:** compared with 0.1.4 over 6,359 programs, the only differences are the new tests and examples. Three existing programs now keep a plain temporary receiver in a slot, which changes the generated Zig but not their output.

## Requirements

Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #46 (fix), #47 (version).
