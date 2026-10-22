# Reading questions and answer key

Line numbers are the same in all four variants (A, B, C, D), so one key
serves every group. The questions name no sigil, so they can be shown
unchanged to every group. Each program's full output is in
`key/outputs/pNN.out`; each rejected program's compiler message is in
`key/outputs/rNN.err` (the message is printed in variant A's spelling,
since the compiler speaks A).

"Modified" means the value's contents may change on that line, whether
directly or through a function or method it is handed to for writing.

---

## p01 — inventory

1. What does line 23 print?
   **`32`** (4×3 + 0×1 + 2×10).
2. What does line 25 print?
   **`bolt 4`** (`first` is a lasting read view of `items[0]`).
3. List every line in `main` (lines 18–33) where `items` may be modified.
   **20, 21, 22, 26.** (24 makes a read view; 23, 28 and 33 only read.)
4. How many times does line 32 run, and what does line 33 print?
   **Once, printing `low: gear`; line 33 prints `37 0`.** Line 26 restocked
   `nut` to 5, so no item is out of stock (line 29 is a negation) and only
   `gear` (2) is not above 3 (line 31 negates the whole comparison).

## p02 — word counter

1. Lines 15 and 36 call `find`. May `find` modify `entries`?
   **No.** Its parameter is a read view; the bare argument is a read.
2. List the lines in `add` (14–18) that may modify `entries`' contents.
   **16 and 18** (16 changes a count, 18 appends).
3. What does line 35 print?
   **`top: cat 2`.** Line 33 skips "the" (the second test is a negation
   of `e.word == "the"`), and "cat" is the only other word seen twice.
4. What does line 36 print?
   **`6 3 -1`.**

## p03 — bank ledger

1. After line 27, what are `ann`'s and `bob`'s balances?
   **ann 70, bob 50.**
2. What does line 28 print, and does any balance change?
   **`failed: Bank.insufficient`; no balance changes** (bob has 50 < 80).
3. What does the last character of line 17 do: negate, lend for writing,
   or pass a failure on?
   **Passes a failure on** (if `withdraw` fails, `transfer` fails with the
   same error, and line 18 does not run).
4. What do lines 33–35 print?
   **`ann 70`, then `bob 45`.** `bob.frozen` is true (line 31), so the
   negation is false and `or` evaluates `report(ann)`, which prints
   `ann 70`; 70 is not unequal to 70, so line 34 does not run; line 35
   prints `bob 45`.

## p04 — job queue

1. What does line 26 do to `q`?
   **Removes its first job** (and hands it to `job`); `q` has one job fewer.
2. Line 25: under what condition does the loop keep going?
   **While `q` is not empty** (a negation of `q.is_empty()`).
3. What does line 31 print, over the whole loop, in order?
   **`ran 1 5`, `ran 3 1`, `ran 4 0`.** (Job 2, cost 7, is skipped at
   line 28.)
4. What does line 33 print?
   **`2 0 0 false`.** Line 32 removed `2` from `skipped`.

## p05 — expression parser

1. Line 8: when does `digit` return `none`?
   **When `b` is not a digit** (the condition is a negation).
2. After the call on line 25 returns, has `pos` changed?
   **Yes.** `number` receives `pos` for writing and advances it to the
   `+` or the end of the string.
3. What does line 35 print?
   **`-1 -2`.** "4+x" fails with `Parse.bad`; "5++6" fails with
   `Parse.empty`.
4. What does line 36 print?
   **`700 none 0`.** In line 31 the mark after `digit(s[0])` passes a
   `none` up, so `lead("up7")` is `none`.

## p06 — binary tree

1. List every line in `main` (30–39) where `root` may be modified.
   **33 and 38.** (35, 36, 37 and 39 only read it.)
2. Line 35: may `walk` modify `root`? May it modify `keys`?
   **`root`: no. `keys`: yes.**
3. What does line 36 print?
   **`[20, 30, 40, 50, 70] 210`.**
4. Does line 38 run, and what does line 39 print?
   **Yes (45 is not in the tree, and line 37 negates `contains`); line 39
   prints `255 true`.**

## p07 — shared configuration

1. What does line 19 print?
   **`2 2`.**
2. Does line 20 release the "base" configuration (print `released base`)?
   **No.** It drops only the `base` handle; `web` and `db` still share
   the configuration.
3. Which line causes `released base` to be printed?
   **Line 25** (dropping `web`; `db` let go of base at line 23).
4. Which variable can no longer be used after line 28?
   **`db`** (moved into `running`).

## p08 — files

1. What does line 23 print?
   **`2 3`.**
2. Does line 22 change `log`'s lines?
   **No.** Line 21 gave `backup` a clone of `log.lines`.
3. Which variable can no longer be used after line 24?
   **`log`** (moved into `archive`).
4. Write the output from line 24 to the end of the program, in order.
   **`archive app.log 2`, `close app.log`, `after archive`, `close tmp`,
   `end 3`, `close app.bak`.**

## p09 — shapes

1. Does line 28 change `shapes`? If so, how?
   **Yes: `shapes[1]` becomes a 5-by-8 rectangle** (w 3+2, h 4×2).
2. What do lines 29–30 print?
   **`12`, `40`, `0`.**
3. What does line 32 print?
   **`big circle 2`.**
4. What does line 34 print?
   **`400 false`** (a Pixel is 4 bytes).

## p10 — stack calculator

1. Line 8: what happens to `stack`?
   **Its last element is removed; when there was one, it is bound to `x`.**
2. Is the last character of line 13 a negation, a write, or a failure
   propagation?
   **A failure propagation** (if `take` fails, `apply` fails).
3. What do lines 33 and 34 print?
   **`14`, then `2`.**
4. What do lines 35 and 39 print?
   **`-1 -2`, then `6`.**

## p11 — task list

1. After line 24, what is `tasks[1].due`?
   **`none`** (`postpone` changes only a due date that exists).
2. What does line 28 print, over the loop, in order?
   **`rent -4`, `call -1`, `taxes 20`.** In line 15 the mark after `due`
   passes a `none` up, so `call` gives `none`, and `?? -1` turns it into -1.
3. What does line 31 print?
   **`2 8`** (two tasks are not done; "bring id" has 8 bytes).
4. Does line 32 change `tasks`? What does line 34 print?
   **Yes, it removes the last task; line 34 prints `2`.**

## p12 — game

1. Line 22: if `players` changes later, does `start` change?
   **No.** `start` is a clone.
2. List every line in `main` (18–33) where `players` may be modified.
   **20, 21, 27, 28, 29, 30.** (27 lends every player to write and 28
   bumps a score; 29 makes a write view of one player and 30 writes
   through it. 32 and 33 only read.)
3. Line 31: when is `done` true?
   **When neither player is alive** (both calls are negated).
4. What do lines 32 and 33 print?
   **`4 ana 10`, then `0 true`.**

---

## Rejected programs

For each, ask: **"This program is rejected by the compiler at one line.
Which line, and why?"**

| Program | Line | Why |
|---|---|---|
| r01 | **11** | `charge` received the account as a read view (line 9), so it cannot change `a.balance`. Compiler: `cannot assign through a read view` |
| r02 | **18** | `r` was moved into `archive` at line 16, so `r.pages` is used after a move. Compiler: ``use of `r` after move`` |
| r03 | **14** | `pop` changes `cart.items`, but the call does not lend `cart.items` to write. Compiler: ``method `pop` needs its receiver lent to write`` |
| r04 | **14** | Line 13 makes `top`, a read view of `list[1]`, which is still used on line 15, so `list` cannot be written (pushed to) on line 14. Compiler: ``cannot lend `list` to write while a read loan is live`` |

Accept an answer that gives the right line and a reason of the same
substance. Common wrong answers worth recording: r01 line 16 (the call
site), r03 line 15, r04 line 12 or 13.
