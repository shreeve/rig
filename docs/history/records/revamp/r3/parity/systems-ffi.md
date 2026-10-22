# systems-ffi

## Parity means
A GPUI-class or OS-facing package hides unsafe code behind a safe API with a provable obligation, as under RustBelt; that code is counted and outside λRig.

## Must build
1. **`extern zig` for packages** (medium). Only std may today (SPEC §15). Unsafe code lives in Zig (pointers, `extern struct`, volatile, asm), not a second unsafe Rig. A package opts in as `trusted`; `rig check` lists trusted files.
2. **Zig-backed types** (`obj Window owns`, ROADMAP) (medium). Each declares kind, drop, clone, later both thread facts. Windows, Metal buffers, mmaps become owners lending `from self`.
3. **C layout and callbacks** (medium). `obj Vertex c` lowers to `extern struct`; an `export sub` with C-typed parameters is C-callable; `void*` context stays in the shim.
4. **An "every bit pattern valid" fact** (small). Plain, C layout, no Bool, enum or padding: `[]U8` then reinterprets as `[]T`, alignment checked. Replaces transmute (#99571).
5. **Allocators as owners** (large). A container built `in a` carries a read loan of arena `a`, so it is view-kind (Core §1); it holds only plain values or values `in a` (arena drop runs no element drop). Rust's `allocator_api` (#32838) is stalled.
6. **Module state** (small). A module `var` is plain, used by value, never lent, so no loan aliases it. No owning globals: app state is `!app` from `main`, which is GPUI's `cx`. Rust is dropping `static mut` (#114447).

## Leave out, and it dissolves
- **Raw pointers in Rig.** λRig needs no aliasing model of user code. Intrusive containers go in trusted Zig.
- **Inline asm, untagged unions, variadic calls (objc_msgSend), transmute.** Zig shims carry them.
- **General `@bitCast`.** Keep it numeric-only (`castProblem`).

## Proof obligations
- **Stage 4, per Zig-backed declaration:** the body inhabits its Rig signature's semantic type: consumes what is moved, retains no view outside `keeps`, a `from` result points only into that owner, drop frees exactly what is owned. Same for std and packages; no open-world Iris.
- **Stage 2:** the interpreter runs each declaration by its spec.
- **Stage 1:** document the Zig subset emit uses and lint emitted code against it, so trust is in that subset. `--release=fast` is outside the claim.

## Disagreements
- RUST-TRIAGE's raw pointers and ROADMAP's asm in `raw` add a second unsafe language Zig makes needless.
- formal-methods' "no user unsafe" locks GPUI-class code out; trusted packages cost the same per-declaration proof as std.
- `noalias` binds trusted Zig too; specs must say so.
