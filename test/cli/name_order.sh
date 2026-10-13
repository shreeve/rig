# A parameter, local, loop variable, binding, or closure parameter may not
# take the name of a module-level declaration, and a module-level name is
# visible throughout the module: the verdict is the same whether the
# declaration comes before or after the use, in one file or across the
# files of a directory module. Every declaration kind x clashing site x
# order is written and checked.
source "$ROOT/test/cli/_lib.sh"

decl() { case $1 in
obj) printf 'obj Thing\n  v: Int\n';;
fun) printf 'fun Thing() -> Int\n  1\n';;
const) printf 'Thing = 5\n';;
enum) printf 'enum Thing\n  a\n  b\n';;
error) printf 'error Thing\n  bad\n';;
alias) printf 'type Thing = Int\n';;
generic) printf 'obj Thing[T]\n  v: T\n';;
use) printf 'use std.math as Thing\n';;
esac; }
site() { case $1 in
param) printf 'fun site(Thing: Int) -> Int\n  1\n';;
tparam) printf 'fun site[Thing](a: Thing) -> Thing\n  a\n';;
local) printf 'fun site() -> Int\n  Thing = 1\n  Thing\n';;
for) printf 'fun site() -> Int\n  for Thing in 0..2\n    print(Thing)\n  1\n';;
match) printf 'enum Sh\n  circle(r: Int)\n  point\n\nfun site(s: Sh) -> Int\n  match s\n    .circle(Thing) => return Thing\n    .point => return 0\n';;
lambda) printf 'fun site() -> Int\n  f = |Thing: Int| Thing\n  f(1)\n';;
ifas) printf 'fun site(o: Int?) -> Int\n  if o as Thing\n    return Thing\n  1\n';;
catch) printf 'error E\n  bad\n\nfun p() -> Int!\n  return E.bad\n\nfun site() -> Int\n  n = p() catch |Thing| 3\n  n\n';;
test) printf 'test "t"\n  Thing = 1\n  print(Thing)\n';;
method) printf 'obj Foo\n  v: Int\n\nfun Foo.m(?self, Thing: Int) -> Int\n  Thing\n';;
esac; }
main() { printf 'sub main()\n  print(1)\n'; }

for d in obj fun const enum error alias generic use; do
    for s in param tparam local for match lambda ifas catch test method; do
        { decl $d; echo; site $s; echo; main; } >before.rig
        { site $s; echo; decl $d; echo; main; } >after.rig
        for o in before after; do
            out=$("$RIG" check $o.rig 2>&1); rc=$?
            expect_rc $rc 1 "$d declared, $s clashes, declaration $o"
            first=$(sed -n 's/^[^ ]* error: //p' <<<"$out" | head -1)
            [[ $o == before ]] && msg_before=$first || msg_after=$first
        done
        expect_eq "$msg_before" "$msg_after" "$d/$s: same diagnostic in both orders"
        [[ $d == use || ( $d == const && ( $s == local || $s == test ) ) ]] || expect_has "$msg_after" "has the same name as the module-level declaration" "$d/$s"
    done
done

# Files of a directory module, either one first.
for first in a b; do
    second=$([[ $first == a ]] && echo b || echo a)
    mkdir -p "dm_$first/m"
    printf 'pub obj Thing\n  v: Int\n' >"dm_$first/m/$first.rig"
    printf 'pub fun site[Thing](x: Thing) -> Thing\n  x\n' >"dm_$first/m/$second.rig"
    printf 'use m\n\nsub main()\n  print(m.site(1))\n' >"dm_$first/main.rig"
    out=$("$RIG" check "dm_$first/main.rig" 2>&1); rc=$?
    expect_rc $rc 1 "directory module, declaration in $first.rig"
    expect_has "$out" "has the same name as the module-level declaration" "directory module, declaration in $first.rig"
done

# A name that is not module-level is free: the same names in two modules
# do not clash.
printf 'pub obj Thing\n  v: Int\n' >other.rig
printf 'use other\n\nfun site(Thing: Int) -> Int\n  Thing\n\nsub main()\n  print(site(2))\n' >ok.rig
out=$(rig run ok.rig 2>&1); expect_rc $? 0 "name in another module"
expect_eq "$out" "2" "name in another module"

# Clash errors print in source order among the module's other errors.
cp "$ROOT/test/reject/names/errors_in_source_order.rig" order.rig
out=$("$RIG" check order.rig 2>&1)
where=$(sed -n 's/^order.rig:\([0-9]*:[0-9]*\): error:.*/\1/p' <<<"$out" | tr '\n' ' ')
expect_eq "$where" "1:7 7:5 17:7 17:19 " "clash errors in source order"
