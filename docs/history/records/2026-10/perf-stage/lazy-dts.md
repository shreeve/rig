# Lazy binding of declaration files: the bound (2026-11-01)

Owner-approved measurement only (relayed by Rig - Swiss): what binding the
member lists of unchecked declaration files only when first asked, as tsrs
does by default (notes/mem-lazy-dts-members.md in tsrs), could save Trig.

Arms, Trig main `fb60a18` built `--release` by Rig `5fd1ff38f`, each with the
phase timers ([head-phases-data/timers.diff](head-phases-data/timers.diff)); the Mac, one checker, fastest of 7;
`PHASE bind` (the program's bind loop):

- **main**
- **bound**: a declaration file's interfaces, classes and type literals bind
  nothing inside (worktree trig/lazy-dts-bound). The output is wrong (the
  checker panics after binding); bind time only.
- **intern**: as bound, but each member with a plain name (identifier, string,
  number) has its name interned in order, as the first bind would; no symbols,
  no tables (Rig - Merges' option (a), which keeps atom order for the parallel
  bind's merge). Computed names (`[Symbol.iterator]`) are left out, so this
  slightly undercounts what (a) keeps.

| project | main | bound | intern | (a) saves |
|---|---:|---:|---:|---:|
| empty (zod3's libs) | 3.06 ms | 0.76 | 1.23 | 1.83 ms |
| zod3 | 4.64 ms | 2.58 | 2.96 | 1.68 ms |
| ts-pattern | 5.20 ms | 2.81 | 3.33 | 1.87 ms |

Before paying for what the checker asks for: each list it needs is bound
on first use (tsrs: about 24% of the members of asked-for lists were never
looked up, and most lists in unchecked files never asked for). At four
checkers, Merges' parallel bind takes binding off the serial head, so there
the gain is cycles and the critical file.

Next, if pursued: a prototype that binds a skipped list on the checker's
first ask (members, exports, symbol lookups of member names), outputs
identical to tsc on the six projects at one and four checkers, timed with
time-ab.sh and an A/A arm, with and without Merges' parallel bind.

The bound arm's patch is [lazy-dts-data/bound.diff](lazy-dts-data/bound.diff);
the intern arm's binder (`intern-arm-binder.rig`, 152 KB) is on pup in
`/zfs/trig-pup/records-data/lazy-dts/`.
