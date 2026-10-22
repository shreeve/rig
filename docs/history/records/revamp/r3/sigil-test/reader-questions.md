# Reading questions

Answer each question about the programs in this folder. Line numbers refer to the program named in the heading. "Modified" means the value's contents may change on that line, whether directly or through a function or method it is handed to for writing.

## p01 — inventory

1. What does line 23 print?
2. What does line 25 print?
3. List every line in `main` (lines 18–33) where `items` may be modified.
4. How many times does line 32 run, and what does line 33 print?

## p02 — word counter

1. Lines 15 and 36 call `find`. May `find` modify `entries`?
2. List the lines in `add` (14–18) that may modify `entries`' contents.
3. What does line 35 print?
4. What does line 36 print?

## p03 — bank ledger

1. After line 27, what are `ann`'s and `bob`'s balances?
2. What does line 28 print, and does any balance change?
3. What does the last character of line 17 do: negate, lend for writing,
   or pass a failure on?
4. What do lines 33–35 print?

## p04 — job queue

1. What does line 26 do to `q`?
2. Line 25: under what condition does the loop keep going?
3. What does line 31 print, over the whole loop, in order?
4. What does line 33 print?

## p05 — expression parser

1. Line 8: when does `digit` return `none`?
2. After the call on line 25 returns, has `pos` changed?
3. What does line 35 print?
4. What does line 36 print?

## p06 — binary tree

1. List every line in `main` (30–39) where `root` may be modified.
2. Line 35: may `walk` modify `root`? May it modify `keys`?
3. What does line 36 print?
4. Does line 38 run, and what does line 39 print?

## p07 — shared configuration

1. What does line 19 print?
2. Does line 20 release the "base" configuration (print `released base`)?
3. Which line causes `released base` to be printed?
4. Which variable can no longer be used after line 28?

## p08 — files

1. What does line 23 print?
2. Does line 22 change `log`'s lines?
3. Which variable can no longer be used after line 24?
4. Write the output from line 24 to the end of the program, in order.

## p09 — shapes

1. Does line 28 change `shapes`? If so, how?
2. What do lines 29–30 print?
3. What does line 32 print?
4. What does line 34 print?

## p10 — stack calculator

1. Line 8: what happens to `stack`?
2. Is the last character of line 13 a negation, a write, or a failure
   propagation?
3. What do lines 33 and 34 print?
4. What do lines 35 and 39 print?

## p11 — task list

1. After line 24, what is `tasks[1].due`?
2. What does line 28 print, over the loop, in order?
3. What does line 31 print?
4. Does line 32 change `tasks`? What does line 34 print?

## p12 — game

1. Line 22: if `players` changes later, does `start` change?
2. List every line in `main` (18–33) where `players` may be modified.
3. Line 31: when is `done` true?
4. What do lines 32 and 33 print?


## Rejected programs (r01–r04)

Each of r01, r02, r03 and r04 is rejected by the compiler at exactly one line.
For each: which line, and why?
