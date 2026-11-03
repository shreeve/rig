# Revamp of the runtime and std: decisions for the owner (2026-11-03)

Each is a name, a public signature, or a behavior change, which the revamp
left for the owner. Each has a default; "approve the defaults" takes all of
them. Evidence is in audit-std.md and audit-runtime.md beside this file.

1. **std.json's names** (audit-std, API table). `json.new_doc()` becomes
   `json.Doc()`, `doc.size()` becomes `doc.len`, and `get_bool`, `get_int`,
   `get_float`, `get_str` become `doc.bool(i)`, `doc.int(i)`,
   `doc.float(i)`, `doc.string(i)`. The error kinds become
   `JsonError.Kind`. The old names are rejected with a hint, and a migration
   script ships with the change. Default: **yes**.
2. **`compare` returns `Order`** in std.text and std.bigint, as
   `x.order(?y)` does, not -1/0/1. Default: **yes**.
3. **One spelling for equality and floats.** `bigint`'s `a.equals(b)`
   becomes `equal`, as in `crypto.equal`, and `to_f64` becomes `to_float`.
   Default: **yes**.
4. **Search takes a view of what it looks for** (S10).
   `slices.contains`, `index_of`, `sort.lower_bound`, and `search` take
   `x: ?T`, so a `List[String]` is searched without giving up or cloning a
   String. Callers write `?x`. Default: **yes**, with a migration script.
5. **std.iter goes** (S9). `iter.count` and `iter.sum` repeat the chains'
   `count()` and `sum()`; the one difference is `sum` of nothing, which is
   `none` there and 0 in a chain. Default: **yes**; 4 tests migrate.
6. **BigInt provides `Eq` and `Ord`.** STD forbids `==` on a BigInt
   because it would hide a walk over the limbs, but `String ==` and
   `List ==` walk too. Default: **yes**, through `equal` and `compare`.
7. **The hash seed** (S2). HashMap hashes an Int key by an unseeded
   multiply and text by a fixed seed, so keys from the network can be made
   to collide. A per-process seed fixes that, but makes a HashMap's order
   differ from run to run. Map's order is unchanged either way. Default:
   **keep the fixed seed** (STD now documents the risk for HashMap as for
   Map), and add a seeded constructor later if a program needs one.
8. **`random.int` by multiply-and-reject** (S32), one multiply where it
   now divides twice. Seeded sequences change, and the doc examples
   that print them update. Default: **yes**.
9. **`math.powf`** keeps its name. Default: **keep**.
10. **New public names from #903:** `utf8.block_errors` and
    `utf8.weighted_count[four]`, which std.json and std.utf16 use.
    Default: **keep**.
11. **Small blocks back to the system.** Small blocks never leave their
    size class, so a program that frees a phase's blocks of one size and
    then allocates another holds both peaks. Default: **measure first**
    on Trig and xmalloc-test before any design.
12. **Printing deep values.** A value nested more than 64 deep prints
    `...`. Detecting cycles by address would print acyclic data whole.
    Default: **keep the depth limit**.
