# `@name` of a type parameter takes every Rig name from sema's type
# printer, which the emitter writes into the module's table of names
# (`__rig_names`) and into each type it emits (`__rig_name`). The
# runtime's code that names a type (`rig.typeName`) spells none itself,
# so renaming a type is a change to the printer alone.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
struct Point
  x: Int

fun name[T]() -> String
  @name(T)

sub main()
  print(name[Vec[Point]](), @name(Point))
EOF2

"$RIG" emit main.rig >main.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat main.zig)" 'pub const __rig_name = .{ .module = "", .name = .{ "Point" } };' "the name written into a type"
expect_has "$(cat main.zig)" '.{ i64, "Int" },' "the table of built-in types"
expect_has "$(cat main.zig)" '.{ rig.Vec, .{ "Vec[", 0, "]" } },' "the table of the runtime's generic types"

# The names the table holds: each built-in type's, and the name that
# starts each generic type's spelling.
names=$(sed -n '/^const __rig_names = /,/^};/p' main.zig |
    sed -nE 's/^ *\.\{ [^,]+, "([A-Za-z0-9]+)" \},$/\1/p; s/^ *\.\{ [^,]+, \.\{ "([A-Za-z0-9]+)\[".*/\1/p')
(( $(wc -l <<<"$names") >= 20 )) || fail "too few names in the table: $names"

section=$(sed -n '/^\/\/ Type names$/,/^\/\/ Zig-backed declarations$/p' "$ROOT/src/runtime.zig")
expect_has "$section" "pub fn typeName(" "the runtime's section that names types"
while read -r n; do
    if grep -nE "\"$n(\"|\\[)" <<<"$section"; then fail "src/runtime.zig spells the type name $n"; fi
done <<<"$names"

rig run main.rig >out.txt 2>err.txt || fail "rig run: $(cat err.txt)"
expect_eq "$(cat out.txt)" "Vec[Point] Point" "the names printed"
