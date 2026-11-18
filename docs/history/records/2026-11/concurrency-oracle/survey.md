# The reference checker over task programs: a survey

2026-11-15, main 61ddd14d5, before the change and after it (branch
`oracle-tasks`). What was modeled is in [notes.md](notes.md).

## Method

`swarm test/rig.rip oracle` writes the oracle's lists
(`.zig-cache/rig-tests/oracle/{tests,docs}.list`); `bin/rig-oracle -v`
gives every function's two verdicts. A function counts as a task
function when its body, comments left out, uses one of: a task call
`f()&`, a wait `>t`, `.cancel(`, `task.all`, `time.within`,
`wait_first`, `Tasks`, `Task[`, `par.map/each/workers/push`, `Actor`,
`Chan` or `.send(`/`.recv(`, `select`, `task.isolate`. The match is by
text, so a few functions are counted that only name the words.

## Before (main 61ddd14d5)

| Set | Task functions | Accepted | Rejected | Abstained |
|---|---|---|---|---|
| tests | 524 | 348 | 45 | 131 |
| docs | 95 | 62 | 6 | 27 |

Why it abstained:

| Reason | tests | docs |
|---|---|---|
| a method reached through a handle | 120 | 22 |
| a write receiver without `!` (`xs.sum()`) | 4 | 1 |
| generic instances and types at owners | 4 | 1 |
| an expression without a type (`inst`, `index`, `block`) | 2 | 2 |
| a name the lowering did not bind, a bare function value | 1 | 1 |

Of the 120 "method reached through a handle", 89 called a method of an
actor through its handle and 31 made the arms of `task.select`
(`on_recv`, `on_send`, `on_end`); after the actor calls were modeled, 31
were left, 30 of them select arms.

By the form they use (a function may use several): Actor 89, `f()&` 42,
`>t` 38, `task.select` 31, Chan 26, `task.isolate` 16, Tasks 10, `par`
6, `time.within` 4, `.cancel` 3, `Task[T]` 3, `task.all` 1.

Over all programs, the sets decided 24,763 of 25,747 functions (tests)
and 1,301 of 1,443 (docs).

## The task rules, before

| Rule | Second opinion before | Kind |
|---|---|---|
| (a) a task keeps its call's loans until waited for or dropped | read loans yes (C4); write loans kept only as read loans, so a read of what a task writes was accepted | ownership |
| (b) a task's drop uses its loans | yes (a task counts as having a `drop` body) | ownership |
| (c) drops and defers in the order they run | yes (`task defer after` rejected), no verdict line | ownership |
| (d) no shared home holds a task | owned closure: abstained; Cell, Signal: abstained in `kinds`; channel, actor: unchecked | ownership (rule 3), also a type rule in sema |
| (e) a task with a write loan only bound and waited | no: accepted with `--sema` | ownership (no value holds a write view), rejected in sema |
| (f) `>t!`, `>t catch \|e\|`, a dropped task's error, `<t.cancel()` | yes, no verdict lines | ownership |
| (g) `-> Task[T] from v` keeps the signature's loans | yes, with verdict lines | ownership |
| a fallible task dropped without waiting | no (`stricter`: `task fallible lost`, `sets lost`) | not ownership: an error-is-not-lost rule (SPEC §18 "Drop") |
| a task as a statement, `<t.cancel()` on an infallible task, a deadline over infallible tasks | no | type rules in sema |

## After

| Set | Task functions | Accepted | Rejected | Abstained |
|---|---|---|---|---|
| tests | 524 | 465 | 51 | 8 |
| docs | 95 | 85 | 6 | 4 |

What is left abstaining, by reason:

| Reason | tests | docs |
|---|---|---|
| generic instances and types at owners | 4 | 1 |
| an expression without a type (`inst`, `index`, `block`) | 2 | 2 |
| a name the lowering did not bind, a bare function value | 1 | 1 |
| a method reached through a handle (a Cell object's function field, through `par`) | 1 | 0 |

None of these is a task rule: each is a form the checker abstains on
wherever it stands.

Over all programs the sets decide 24,922 of 25,747 functions (tests,
159 more) and 1,341 of 1,443 (docs, 40 more), with no function the
compiler accepts and the checker rejects. Six rejections are new, each
the compiler's too: `actor_task_keeps_argument_loans`, and five of the
select (`chan_select_arm_views_what_another_arm_moves`,
`chan_select_arms_lend_to_write`, `chan_select_named_sends_what_it_moves`,
`chan_select_named_in_a_block_a_view_escapes`,
`chan_select_end_lends_the_task`). The counts are on the lists before
the change's new tests, which add verdicts of their own.
