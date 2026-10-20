# std.file.write: a whole file written, replaced, and read back, each
# missing directory on the way made, and each failure a FileError; in
# debug (sanitized) and --release, and from tasks.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >write.rig <<'EOF2'
use std.file

sub put(path: ?String, data: ?String)!
  file.write(path, data) catch |e|
    print(path, e)
    return
  if file.read(path)! as s
    print(path, s.len, s == data)
  else
    print(path, "none")

sub main()!
  put("a.txt", "one two")!
  put("a.txt", "x")!
  put("empty.txt", "")!
  put("deep/er/est/b.txt", "made")!
  put("deep/c.txt", "beside")!
  put("a.txt/c.txt", "under a file")!
  put("deep", "a directory")!
  put("", "no name")!
EOF2

# The same, from tasks waited for with `>`, and bytes that are not text.
cat >tasks.rig <<'EOF2'
use std.file

fun put(path: String, n: Int) -> Bool!
  data = String()
  i = 0
  while i < n
    !data.push(U8(i % 256))
    i += 1
  file.write(?path, ?data) catch return false
  (file.read(?path)! ?? String()) == data

sub main()!
  a = put(String("t/1/a.bin"), 1000)&
  b = put(String("t/2/b.bin"), 300000)&
  c = put(String("t/1/c.bin"), 7)&
  print(>a!, >b!, >c!)
EOF2

# Where the program may not write; root may, so it is left out then.
cat >denied.rig <<'EOF2'
use std.file

sub main()
  for p in ["ro/a.txt", "ro/sub/a.txt"]
    file.write(p, "no") catch |e|
      print(p, e)
EOF2

want='a.txt 7 true
a.txt 1 true
empty.txt 0 true
deep/er/est/b.txt 4 true
deep/c.txt 6 true
a.txt/c.txt FileError.not_directory
deep FileError.is_directory
 FileError.not_found'
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf a.txt empty.txt deep t
    out=$(RIG_SANITIZE=1 rig run $flag write.rig 2>&1); expect_rc $? 0 "$mode write: $out"
    expect_eq "$out" "$want" "$mode: written, replaced, empty, parents made, failures"
    expect_eq "$(cat deep/er/est/b.txt)" "made" "$mode: the bytes on disk"
    out=$(RIG_SANITIZE=1 rig run $flag tasks.rig 2>&1); expect_rc $? 0 "$mode tasks: $out"
    expect_eq "$out" "true true true" "$mode: from tasks"
    expect_eq "$(wc -c <t/2/b.bin | tr -d ' ')" 300000 "$mode: a 300 KB file's size"
    if [[ $(id -u) -ne 0 ]]; then
        rm -rf ro; mkdir ro; chmod 500 ro
        out=$(RIG_SANITIZE=1 rig run $flag denied.rig 2>&1); rc=$?
        chmod 700 ro
        expect_rc $rc 0 "$mode denied: $out"
        expect_eq "$out" $'ro/a.txt FileError.denied\nro/sub/a.txt FileError.denied' "$mode: denied"
    fi
done
exit 0
