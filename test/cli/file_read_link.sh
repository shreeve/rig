# `file.read_link` gives what a symbolic link holds, as written in it and
# unresolved, where `file.realpath` follows every link: a link to a
# file, a relative link, a link that names nothing; `none` when nothing
# is at the path, and `FileError.invalid` for a path that is not a link.
source "$ROOT/test/cli/_lib.sh"

mkdir -p d
: >d/file
ln -s "$PWD/d/file" abs
ln -s d/file rel
ln -s nowhere dangling
ln -s abs chain

cat >links.rig <<'EOF2'
use std.file

sub show(path: ?String)
  got = file.read_link(path) catch |e|
    print(path, e)
    return
  print(path, got ?? String("none"))

sub main()
  for p in ["rel", "dangling", "chain", "missing", "d/file", "d", "d/file/x"]
    show(p)
EOF2
out=$(rig run links.rig 2>&1) || fail "links.rig: $out"
expect_eq "$out" "rel d/file
dangling nowhere
chain abs
missing none
d/file FileError.invalid
d FileError.invalid
d/file/x none" "read_link"

cat >abs.rig <<'EOF2'
use std.file

sub main()!
  print(file.read_link("abs")! ?? String("none"))
EOF2
expect_eq "$(rig run abs.rig 2>&1)" "$PWD/d/file" "an absolute link"
