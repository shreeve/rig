p='SPEC.md'
s=open(p).read()
old='''```error
use of `v` while a write borrow is live
cannot write-borrow a slice of a String; a String is read-only
```

### Composite and handle types
'''
new='''```error
use of `v` while a write borrow is live
cannot write-borrow a slice of a String; a String is read-only
```

### Bytes

Bytes hold fixed-width numbers. `bytes.read[T, e](at)` is the integer
or float `T` stored in the `@sizeOf(T)` bytes from offset `at`, in byte
order `e`, and `!bytes.write[T, e](at, v)` stores `v` there. `T` is any
integer or float type; `e` is a compile-time value of the built-in enum
`Endian`, `.little` or `.big` (a literal, `Endian.big`, a constant, or
a compile-time parameter; there is no native order). `read` works on a
`[]U8`, an `![]U8`, a `[N]U8`, a `Vec[U8]`, and a String; `write` on
the writable ones, written `!bytes` (or an `![]U8` binding). Every byte
must be in range, `0 <= at` and `at + @sizeOf(T) <= len`: a constant
offset into an array is checked at compile time, and any other when the
program runs, which panics in every build mode when it is not. A float
is read and written by its bits, so a NaN's payload survives. `Endian`
is a built-in name, like `Vec`, and is reserved.

```rig
sub main
  page: [4096]U8 = [4096 of 0]
  !page.write[U32, .little](0, 0x52494721)
  !page.write[U16, .big](4, 4088)
  print(page[0], page[1], page[4], page[5])
  print(page.read[U32, .little](0), page.read[U16, .big](4), page.read[U16, .little](4))
  body = !page[8..]
  !body.write[F64, .big](0, 2.5)
  print(page.read[F64, .big](8))
```

```output
33 71 15 248
1380533025 4088 63503
2.5
```

```rig reject
sub main
  b: [8]U8 = [8 of 0]
  print(b.read[U32, .little](6))
  print(b.read[U16, .native](0))
```

```error
`read` of a `U32` at `6` runs past the end of an array of length 8: it needs 4 bytes
no variant `native` on enum `Endian`
```

### Composite and handle types
'''
assert old in s; s=s.replace(old,new,1)
old='''| `Cell[T]`, `Vec[T]`, `Signal[T]` | built-in generic types | [§11](#11-cell-vec-and-signal) |
| `Name`, `Name[T]`, `mod.Name` |'''
new='''| `Cell[T]`, `Vec[T]`, `Signal[T]` | built-in generic types | [§11](#11-cell-vec-and-signal) |
| `Endian` | built-in enum: the byte order of `read` and `write` | [§3](#bytes) |
| `Name`, `Name[T]`, `mod.Name` |'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='SYNTAX.md'
s=open(p).read()
old='''```rig reject
sub main
  a = [1, 2, 3, 4]
  x = !a[..2]
  y = !a[2..]
  x[0] = y[0]
```

```error
cannot take a second write borrow on `a`
```
'''
new='''```rig reject
sub main
  a = [1, 2, 3, 4]
  x = !a[..2]
  y = !a[2..]
  x[0] = y[0]
```

```error
cannot take a second write borrow on `a`
```

**Bytes** hold fixed-width numbers: `buf.read[U16, .big](at)` reads a
`U16` stored big-endian at byte `at`, and `!buf.write[U32, .little](at,
v)` stores one, like Rust's `u16::from_be_bytes` and `to_le_bytes` or
Zig's `std.mem.readInt` and `writeInt`. The type is any integer or
float, and the byte order is a compile-time value of the built-in enum
`Endian` (`.little` or `.big`). The bytes are a `[N]U8`, a `[]U8` or
`![]U8`, a `Vec[U8]`, or (to read) a String, and every byte read or
written must be in range, or the program panics, in every build mode.

```rig
sub main
  page: [4096]U8 = [4096 of 0]
  !page.write[U32, .little](0, 0xcafe)
  hdr = ?page[..8]
  print(page[0], page[1], hdr.read[U32, .little](0), hdr.read[U16, .big](0))
```

```output
254 202 51966 65226
```
'''
assert old in s; s=s.replace(old,new,1)
old='''| `Cell[T]`, `Vec[T]`, `Signal[T]` | built-in generics | `RefCell<T>`, `Vec<T>` | runtime types |'''
new='''| `Cell[T]`, `Vec[T]`, `Signal[T]` | built-in generics | `RefCell<T>`, `Vec<T>` | runtime types |
| `Endian` | byte order: `.little`, `.big` | | `std.builtin.Endian` |'''
assert old in s; s=s.replace(old,new,1)
old='''| `[]T`, `![]T` | `[]const T`, `[]T` |
'''
new='''| `[]T`, `![]T` | `[]const T`, `[]T` |
| `b.read[U16, .big](at)`, `!b.write[U32, .little](at, v)` | `rig.readInt(u16, b, at, .big)` over `std.mem.readInt`, `rig.writeInt` over `std.mem.writeInt` |
'''
assert old in s; s=s.replace(old,new,1)
old='''- **a standard library** beyond `print`, `Cell`, `Vec`, and `Signal`;'''
new='''- **a standard library** beyond `print`, `Cell`, `Vec`, `Signal`, and
  the slice methods (`copy`, `fill`, `swap`, `read`, `write`);'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='docs/INTERNALS.md'
s=open(p).read()
old='''| `elemCallOf(callee)` | for a call of a built-in element method (`!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`): which one |'''
new='''| `elemCallOf(callee)` | for a call of a built-in element method (`!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`, `b.read[T, e](at)`, `!b.write[T, e](at, v)`): which one, and for `read` and `write` the number type `T`; the bracket list is recorded as compile-time arguments (`instanceOf`) |'''
assert old in s; s=s.replace(old,new,1)
old='''| `copy`, `fill`, `swap` | the element methods:'''
new='''| `Endian`, `readInt`, `writeInt` | `b.read[T, e](at)` and `!b.write[T, e](at, v)`: `std.mem.readInt` / `writeInt` on the unsigned integer of `T`'s width, with `@bitCast` for a signed or float `T`, after a check (in every build mode) that `at + @sizeOf(T) <= len`. `Endian` is Rig's built-in enum, which every module's `Endian` symbol names (`importType` maps one module's to another's) |
| `copy`, `fill`, `swap` | the element methods:'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='test/cli/release_checks.sh'
s=open(p).read()
old='''# --release keeps the conversion checks.'''
new='''cat >bytes.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  b: [4]U8 = [1, 2, 3, 4]
  print(b.read[U32, .big](rt(1)))
EOF
"$RIG" build --release=fast -o bin/bytes bytes.rig || fail "rig build --release=fast bytes.rig"
out=$(bin/bytes 2>&1); rc=$?
expect_has "$out" "byte read out of range" "fast build read check"
[[ $rc -ne 0 ]] || fail "fast build: read past the end exited 0"

cat >store.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  b: [4]U8 = [1, 2, 3, 4]
  !b.write[U16, .little](rt(3), 7)
EOF
"$RIG" build --release=fast -o bin/store store.rig || fail "rig build --release=fast store.rig"
out=$(bin/store 2>&1); rc=$?
expect_has "$out" "byte write out of range" "fast build write check"
[[ $rc -ne 0 ]] || fail "fast build: write past the end exited 0"

# --release keeps the conversion checks.'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)
