p='docs/INTERNALS.md'
s=open(p).read()
old='''| `genericCallOf(call)` |'''
new='''| `elemCallOf(callee)` | for a call of a built-in element method (`!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`): which one |
| `genericCallOf(call)` |'''
assert old in s; s=s.replace(old,new)
old='''| `index`, `at`, `elemPtr`, `slice`, `sliceMut`, `div` |'''
new='''| `copy`, `fill`, `swap` | the element methods: `copy` panics in every build mode unless the lengths are equal, then is `@memcpy` (the checker keeps the two slices from overlapping); `fill` is `@memset`; `swap` checks both indexes |
| `index`, `at`, `elemPtr`, `slice`, `sliceMut`, `div` |'''
assert old in s; s=s.replace(old,new)
open(p,'w').write(s)

p='SPEC.md'
s=open(p).read()
old='''```rig reject
sub main
  s = "text"
  v: Vec[Int] = Vec()'''
new='''Three methods write the elements of a `![]T`, an array, or a Vec,
whose receiver is written `!xs` (or is a `![]T` binding):
`!dst.copy(src)` copies a `[]T` of the same length into them, and
panics in every build mode when the lengths differ; `!s.fill(v)` sets
every element to `v`; `!s.swap(i, j)` exchanges two elements, with both
indexes checked. `copy` and `fill` copy values in, so the elements are
plain data; `swap` also moves the handles of a `Vec` of them. `copy`'s
receiver and argument never overlap: the write borrow of the receiver
excludes a read of the same value.

```rig
sub main
  a = [1, 2, 3, 4, 5, 6]
  b = [9, 8, 7]
  !a[..3].copy(?b[..])
  !a[3..].fill(0)
  !a.swap(0, 5)
  print(a)
```

```output
[0, 8, 7, 0, 0, 9]
```

```rig reject
sub main
  a = [1, 2, 3, 4]
  !a[..2].copy(?a[2..])
```

```error
cannot write-borrow `a` while a read borrow is live
```

```rig reject
sub main
  s = "text"
  v: Vec[Int] = Vec()'''
assert old in s; s=s.replace(old,new)
open(p,'w').write(s)

p='SYNTAX.md'
s=open(p).read()
old='''(`for x in !s`).

```rig
sub quicksort(s: ![]Int)'''
new='''(`for x in !s`). `!dst.copy(src)` (lengths must match, as in Rust's
`copy_from_slice`), `!s.fill(v)`, and `!s.swap(i, j)` write the
elements of a `![]T`, an array, or a Vec.

```rig
sub quicksort(s: ![]Int)'''
assert old in s; s=s.replace(old,new)
open(p,'w').write(s)

p='test/cli/release_checks.sh'
s=open(p).read()
old='''# --release keeps the conversion checks.'''
new='''# So do the element methods' checks.
cat >copy.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  b = [4, 5, 6]
  !a.copy(?b[..rt(2)])
EOF
"$RIG" build --release=fast -o bin/copy copy.rig || fail "rig build --release=fast copy.rig"
out=$(bin/copy 2>&1); rc=$?
expect_has "$out" "copy between slices of different lengths" "fast build copy check"
[[ $rc -ne 0 ]] || fail "fast build: copy of a different length exited 0"

cat >swap.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  !a.swap(0, rt(3))
EOF
"$RIG" build --release=fast -o bin/swap swap.rig || fail "rig build --release=fast swap.rig"
out=$(bin/swap 2>&1); rc=$?
expect_has "$out" "index out of bounds" "fast build swap check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-range swap exited 0"

# --release keeps the conversion checks.'''
assert old in s; s=s.replace(old,new)
s=s.replace('''# Release builds keep indexing, slicing, and (with --release) conversion
# checks: each program below panics instead of running on.''','''# Release builds keep indexing, slicing, element-method, and (with
# --release) conversion checks: each program below panics instead of
# running on.''')
open(p,'w').write(s)
