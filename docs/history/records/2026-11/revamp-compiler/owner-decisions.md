# Compiler revamp, phase 1: decisions for the owner (2026-11-03)

Each had a default. A panel of three experts agreed with all five, so all the defaults were approved on the owner's instruction (2026-11-04; panel-decisions.md).

1. **`!` on a `for` source** (audit-frontend F6). `for x in ?b.each()`
   applies `?` to the call's self, but `for x in !b.counter()` takes `!`
   as the loop's mode and rejects the program. The same text means two
   things inside and outside a `for` header. Default: **`!` follows the
   self-sigil rule as `?` does**, as its own change with a SPEC edit.
2. **`collect` of views** (audit-types-2 U4). SPEC "Chains" says `collect`
   of views is rejected, but `List[String]`'s `filter(...).collect()` is
   accepted as a `List[?String]`. That is memory-safe, and the oracle
   agrees. Default: **SPEC says what the code does**: a view of an element
   may be collected while the list it views lives.
3. **Check speed as a merge gate.** `bench/check/guard.py` (fixed in this
   phase) joins the json, hash, and text guards in AGENTS step 6, so check
   speed cannot drift again unnoticed: it grew 27% from 10-15 to 10-31.
   Default: **yes**.
4. **A check-speed round once features settle,** measured on Trig's real
   check (about 2 s) as well as the generated workload, after phase 2.
   Default: **yes**.
5. **Two write captures of one value in a `select`** are rejected (#917).
   Main accepted them and crashed. CORE allows one write view at a time,
   and every arm is made before one runs. Default: **keep the rejection**.
