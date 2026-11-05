# `$embed(path)`: the file's bytes are part of the package, so a build
# after they change builds again and gives the new bytes, through the
# cache home, RIG_BUILD_STORE, a kept `rig build`, a split build, and a
# batch. `rig check` opens the file and reads none of its bytes, so a
# file of 20 MB checks at once; one of 2 GiB or more is rejected with a
# Rig diagnostic (a sparse file, so nothing is written). The messages
# name the path as written, and the file that names it as the user
# spelled it.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

mkdir -p prog/data prog/lib
cat >prog/main.rig <<'R'
use lib

sub main()
  s = $embed("data/words.txt")
  print(s.len, lib.words() == s, s[0..s.len - 1])
R
printf 'pub fun words() -> Static\n  $embed("../data/words.txt")\n' >prog/lib/words.rig
printf 'one two\n' >prog/data/words.txt

out=$(cd prog && rig run main.rig 2>&1); expect_eq "$out" "8 true one two" "the first bytes"
printf 'three four five\n' >prog/data/words.txt
out=$(cd prog && rig run main.rig 2>&1); expect_eq "$out" "16 true three four five" "rig run after the bytes change"

# The cache home: a package directory of its own, kept between runs.
home=$PWD/home
mkdir -p "$home"
printf 'one two\n' >prog/data/words.txt
out=$(cd prog && env -u RIG_OUT_DIR -u RIG_BUILD_STORE XDG_CACHE_HOME=$home "$RIG" run main.rig 2>&1); expect_eq "$out" "8 true one two" "the cache home"
printf 'six\n' >prog/data/words.txt
out=$(cd prog && env -u RIG_OUT_DIR -u RIG_BUILD_STORE XDG_CACHE_HOME=$home "$RIG" run main.rig 2>&1); expect_eq "$out" "4 true six" "the cache home after the bytes change"

# The build store, and an executable `rig build` keeps.
store=$PWD/store
printf 'one two\n' >prog/data/words.txt
out=$(cd prog && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "8 true one two" "the store"
printf 'seven\n' >prog/data/words.txt
out=$(cd prog && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "6 true seven" "the store after the bytes change"
(cd prog && rig build -o ../kept main.rig) || fail "rig build"
expect_eq "$(./kept)" "6 true seven" "a built executable"
printf 'eight nine\n' >prog/data/words.txt
(cd prog && rig build -o ../kept main.rig) || fail "rig build again"
expect_eq "$(./kept)" "11 true eight nine" "a built executable after the bytes change"
(cd prog && rig build --units=2 -o ../split main.rig) || fail "a split build"
expect_eq "$(./split)" "11 true eight nine" "a split build"

# A batch places each embedded file once, by its bytes.
cp -R prog prog2
printf 'ten\n' >prog2/data/words.txt
out=$(RIG_BUILD_STORE=$store "$RIG" batch build b prog/main.rig prog2/main.rig 2>&1); expect_rc $? 0 "a batch: $out"
expect_eq "$("$RIG" batch run b 0)" "11 true eight nine" "the batch's first program"
expect_eq "$("$RIG" batch run b 1)" "4 true ten" "the batch's second program"

# The package holds a copy of the file at its place.
(cd prog && RIG_OUT_DIR=$PWD/../emitted "$RIG" emit main.rig >emitted.zig 2>/dev/null) || fail "rig emit"
cmp -s emitted/__rig_embed/data/words.txt prog/data/words.txt || fail "the package's copy of the file"
expect_has "$(<prog/emitted.zig)" '@embedFile("__rig_embed/data/words.txt")' "the emitted root"

# Checking a 20 MB file reads none of it; a file of 2 GiB is rejected.
head -c 20000000 /dev/zero >prog/data/big.bin
printf 'sub main()\n  print($embed("data/big.bin").len)\n' >prog/big.rig
start=$SECONDS
(cd prog && "$RIG" check big.rig) || fail "check of a 20 MB embed"
(( SECONDS - start < 5 )) || fail "check of a 20 MB embed took $((SECONDS - start)) s"
truncate -s 2147483648 prog/data/huge.bin 2>/dev/null || mkfile -n 2g prog/data/huge.bin || fail "a sparse file"
printf 'sub main()\n  print($embed("data/huge.bin").len)\n' >prog/huge.rig
out=$(cd prog && "$RIG" check huge.rig 2>&1); expect_rc $? 1 "a 2 GiB file"
expect_has "$out" 'huge.rig:2:16: error: $embed: cannot read "data/huge.bin" (the file is 2 GiB or larger), relative to huge.rig' "a 2 GiB file"

# The messages, with the file that names it as spelled.
out=$("$RIG" check prog/lib/../main.rig 2>&1)
expect_rc $? 0 "a path through .."
printf 'pub fun words() -> Static\n  $embed("../data/nothing.txt")\n' >prog/lib/words.rig
out=$("$RIG" check prog/main.rig 2>&1); expect_rc $? 1 "a missing file"
expect_has "$out" 'prog/lib/words.rig:2:10: error: $embed: cannot read "../data/nothing.txt" (no such file), relative to prog/lib/words.rig' "a missing file"
printf 'pub fun words() -> Static\n  $embed("../../x.txt")\n' >prog/lib/words.rig
out=$("$RIG" check prog/main.rig 2>&1); expect_rc $? 1 "a path above the program"
expect_has "$out" '$embed: "../../x.txt" leaves the program'"'"'s directory, prog;' "a path above the program"

# On macOS an embed's symbol is local, never a weak definition: one weak
# definition makes the executable bind weak symbols, which dyld resolves
# at every launch (9 million instructions a run for Trig's embeds).
if [[ $(uname) == Darwin ]] && command -v otool >/dev/null; then
    printf 'sub main()\n  s = $embed("data/words.txt")\n  print(s.len, s[0..s.len - 1])\n' >prog/one.rig
    (cd prog && rig build --release -o ../rel one.rig) || fail "a release build"
    expect_eq "$(./rel)" "11 eight nine" "a release build's bytes"
    flags=$(otool -hv rel | tail -1)
    [[ $flags != *WEAK* ]] || fail "the release build binds weak symbols: $flags"
fi
