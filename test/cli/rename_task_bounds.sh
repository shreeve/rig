# tools/rename-task-bounds.py renames the task bounds `Moves` and `Shares`
# to `Sends` and `Syncs` in a tree's programs, test cases, and Markdown,
# where they stand in code: a program `rig check` rejected with the new
# names then checks and runs. It leaves strings, comments, a member of
# another module, and a program that declares its own `Moves`; a dry run
# prints the diff and changes nothing; a second run changes nothing.
source "$ROOT/test/cli/_lib.sh"

script=$ROOT/tools/rename-task-bounds.py
mkdir -p tree/own tree/docs
cat >tree/jobs.rig <<'RIG'
# A job's bound was `Moves` before; this comment keeps the word.
api Job: Moves
  fun run(?@) -> Int

obj Add: Job
  n: Int

  fun run(?@) -> Int
    @n + 1

fun hand[T: Moves + Clone](x: T) -> T
  +x

fun look[T: Shares](x: ?T) -> Int
  1

sub main()
  b: ^{Job + Moves} = ^Add(n: 2)
  print(hand(3), look(?4), b.run(), "Moves and Shares")
RIG
cat >tree/own/own.rig <<'RIG'
obj Moves
  n: Int

fun count(m: ?Moves) -> Int
  m.n

sub main()
  print(count(?Moves(n: 5)))
RIG
cat >tree/docs/guide.md <<'MD'
A job's API builds on `Moves`, and a reader's on `Shares`: `[T: Shares]`.
The section on Moves stays.

```rig
fun hand[T: Moves](x: T) -> T
  x

sub main()
  print(hand(1))
```

```zig
const Moves = 1;
```
MD
cat >tree/cases.rig.test <<'TEST'
test "a bound", 7
  fun hand[T: Moves](x: T) -> T
    x
  hand(7)

fail "the old name", "`Moves` is now `Sends`"
  print(1)
TEST
cp -R tree before

out=$(rig check tree/jobs.rig 2>&1); expect_rc $? 1 "before: rejected"
expect_has "$out" "\`Moves\` is now \`Sends\`" "before: the new name"
expect_has "$out" "\`Shares\` is now \`Syncs\`" "before: the other new name"

python3 "$script" --dry-run tree >out.txt 2>&1 || fail "dry run: $(cat out.txt)"
expect_has "$(cat out.txt)" "+api Job: Sends" "the dry run's diff"
diff -r tree before >/dev/null || fail "the dry run changed the tree"

python3 "$script" tree >out.txt 2>&1 || fail "rename: $(cat out.txt)"
jobs=$(cat tree/jobs.rig)
expect_has "$jobs" "api Job: Sends" "an API's header"
expect_has "$jobs" "fun hand[T: Sends + Clone](x: T) -> T" "a bound beside another"
expect_has "$jobs" "fun look[T: Syncs](x: ?T) -> Int" "Shares"
expect_has "$jobs" "b: ^{Job + Sends} = ^Add(n: 2)" "an object's braces"
expect_has "$jobs" "# A job's bound was \`Moves\` before; this comment keeps the word." "a comment"
expect_has "$jobs" '"Moves and Shares")' "a string"
cmp -s tree/own/own.rig before/own/own.rig || fail "a program's own Moves changed: $(cat tree/own/own.rig)"
expect_has "$(cat out.txt)" "CHECK tree/own/own.rig:1:" "its own Moves is reported"
guide=$(cat tree/docs/guide.md)
expect_has "$guide" 'builds on `Sends`, and a reader'"'"'s on `Syncs`: `[T: Syncs]`.' "prose spans"
expect_has "$guide" "The section on Moves stays." "prose outside a span"
expect_has "$guide" "fun hand[T: Sends](x: T) -> T" "a doc's program"
expect_has "$guide" "const Moves = 1;" "a Zig block"
cases=$(cat tree/cases.rig.test)
expect_has "$cases" "  fun hand[T: Sends](x: T) -> T" "a test case"
expect_has "$cases" 'fail "the old name", "`Moves` is now `Sends`"' "a case's expected error"

out=$(rig run tree/jobs.rig 2>&1); expect_rc $? 0 "after: runs ($out)"
expect_eq "$out" "3 1 3 Moves and Shares" "after: the output"
out=$(rig run tree/own/own.rig 2>&1); expect_rc $? 0 "its own Moves runs ($out)"

cp -R tree once
python3 "$script" tree >out.txt 2>&1 || fail "second run: $(cat out.txt)"
diff -r tree once >/dev/null || fail "the second run changed the tree: $(diff -r tree once)"
