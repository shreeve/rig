# Rust forms in four libraries the ports lean on (2026-10-31)

Counts by `libcensus.py` (beside this file): pattern matches over code with
comments and strings removed, not parses.

| Rust form | uucore | ring | tokio | tokio-util+stream | per 1,000 lines |
|---|---:|---:|---:|---:|---:|
| code lines | 28,246 | 18,746 | 51,358 | 9,834 | 108,184 |
| trait declaration | 19 | 38 | 41 | 14 | 1.0 |
| impl Trait for Type | 171 | 173 | 938 | 316 | 14.8 |
| derive(...) items | 368 | 186 | 586 | 128 | 11.7 |
| generic fn/struct/enum/impl <T> | 95 | 284 | 1,180 | 454 | 18.6 |
| where clause | 20 | 77 | 373 | 178 | 6.0 |
| trait bound T: Trait | 60 | 85 | 516 | 108 | 7.1 |
| impl Trait (arg/return) | 93 | 52 | 117 | 6 | 2.5 |
| dyn Trait | 58 | 38 | 25 | 5 | 1.2 |
| lifetime 'a | 135 | 756 | 1,492 | 354 | 25.3 |
| blanket impl<T> Trait for T | 1 | 2 | 4 | 5 | 0.1 |
| associated type | 26 | 69 | 196 | 126 | 3.9 |
| Send / Sync bound or impl | 1 | 8 | 372 | 58 | 4.1 |
| Pin< / Future / poll | · | · | 1,056 | 459 | 14.0 |
| PhantomData | 15 | 80 | 133 | 15 | 2.2 |
| macro_rules! | 22 | 30 | 110 | 17 | 1.7 |
| #[cfg(...)] | 707 | 253 | 1,163 | 70 | 20.3 |
| unsafe impl | · | · | 120 | 5 | 1.2 |
| .clone() | 53 | 10 | 313 | 29 | 3.7 |
| Rc / Arc | 20 | · | 446 | 53 | 4.8 |
| Box< | 64 | 8 | 83 | 10 | 1.5 |
| Mutex / RwLock / RefCell / Cell | 28 | · | 323 | 16 | 3.4 |
| &mut | 386 | 680 | 2,654 | 872 | 42.4 |
| unsafe | 185 | 399 | 1,070 | 32 | 15.6 |
| async / .await | · | · | 735 | 62 | 7.4 |
