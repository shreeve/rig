# Rust forms in the originals of the Rig ports (2026-10-31)

Counts by `libcensus.py` (beside this file), as in [lib-census.md](lib-census.md).

| Rust form | coreutils (ported tools) | sanstun | mini-redis | ray-trace | lists | per 1,000 lines |
|---|---:|---:|---:|---:|---:|---:|
| code lines | 25,702 | 5,645 | 2,094 | 315 | 834 | 34,590 |
| trait declaration | 14 | 2 | · | 2 | · | 0.5 |
| impl Trait for Type | 106 | 28 | 11 | 5 | 16 | 4.8 |
| derive(...) items | 220 | 80 | 35 | 1 | · | 9.7 |
| generic fn/struct/enum/impl <T> | 113 | 15 | 2 | 3 | 46 | 5.2 |
| where clause | 15 | · | · | · | · | 0.4 |
| trait bound T: Trait | 101 | 3 | 2 | 3 | 1 | 3.2 |
| impl Trait (arg/return) | 98 | 9 | 7 | 1 | 1 | 3.4 |
| dyn Trait | 74 | · | 2 | 2 | · | 2.3 |
| lifetime 'a | 440 | 31 | 4 | 2 | 46 | 15.1 |
| .clone() | 70 | 8 | 10 | · | 6 | 2.7 |
| Rc / Arc | 27 | 7 | 7 | · | 10 | 1.5 |
| Box< | 58 | 3 | 2 | 1 | 5 | 2.0 |
| Mutex / RwLock / RefCell / Cell | 11 | 2 | 3 | · | 8 | 0.7 |
| &mut | 636 | 262 | 120 | 1 | 72 | 31.5 |
| unsafe | 22 | · | · | · | 8 | 0.9 |
| async / .await | · | · | 275 | · | · | 8.0 |
