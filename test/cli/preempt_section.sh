#!/usr/bin/env bash
# Preemption by signal keeps the scheduler's code out of the program's own
# code section, where a signal may stop it (docs/history/records/2026-11/
# preempt/design.md, "TLS and the worker"): every scheduler entry the
# program reaches is a call never inlined into it, and `me()` panics when
# one is. This checks it without running every path: bench/tasks and
# bench/actors are built with the option, and each instruction in their
# section (`rig_text`) whose debug line lies in sched.zig must belong to
# one of the functions allowed there, which read a slot or a clock, or
# take a lock that counts for preemption. No body of a scheduler entry
# (`wakeIn`, `commitWaitIn`, and the rest) may appear, nor a lock taken
# uncounted (`lockApart`, `unlockApart`), nor a line of tasks.zig's
# mailbox entries, whose locks go uncounted (docs/history/records/
# 2026-11/preempt/locks-2026-11-05.md), nor any read of a thread-local
# (`%fs:`), whose address a fiber resumed on another worker would still
# hold.
#
# It also checks what the section calls outside it: a preempted task is
# stopped only in the section, so a function the program calls that runs
# outside it holds the task past its slice. Each call from the section
# to a function defined elsewhere must match a line of
# test/cli/preempt_calls.txt, which says why that function stays out;
# calls.rig, below, reaches the runtime's helpers of each kind (`%` and
# `/`, comparisons of text, Map and HashMap, closures, slices, sorting).
#
# Preemption is built for Linux x86-64 and arm64 macOS. On Linux x86-64
# the benches are built as `rig build` builds them; elsewhere `rig emit`
# writes their package and Zig compiles it for x86-64 Linux, with `rig
# build --release=fast`'s flags. On arm64 macOS they are also built
# natively, and the object `bin/rig` links (`__rig_program-apart.o`,
# whose `__TEXT,__rig_text` is the section, with its debug lines) is
# read: there no instruction in the section may use x15, the register
# the trampoline returns by, nor read a thread-local (a TLVP relocation),
# whose address a fiber resumed on another worker would still hold. An
# LLVM `objdump` reads either.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

command -v objdump >/dev/null || exit 0
objdump --version 2>/dev/null | grep -q LLVM || [[ $(uname -s) == Linux ]] || exit 0

# The functions of sched.zig whose code may sit in the program's section.
allowed="current nowNs seed computed lock unlock lockGraph unlockGraph block unblock leadsOn taken free join waitEnd settleLeftCalls wakeLeft"
# The functions of tasks.zig whose code may not: the mailbox entries'
# bodies, which take the actor's lock uncounted.
apart="sendIn takeIn"

# The functions of `file` whose lines are `lines`: the nearest `fn`
# declaration above each.
functions() {
    awk -v want="$(tr '\n' ' ' <<<"$2")" '
        BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) need[w[i]] = 1 }
        /^ *(pub )?(inline |noinline )?fn [A-Za-z_]+/ {
            match($0, /fn [A-Za-z_]+/); name = substr($0, RSTART + 3, RLENGTH - 3)
        }
        NR in need { print name }
    ' "$1" | sort -u
}

# check BIN SECTION NAME: the scheduler's code in BIN's SECTION, as above.
check() {
    local bin=$1 sect=$2 p=$3
    objdump -h "$bin" | grep -q " $sect " || fail "bench/$p has no $sect section"
    dis="$p$sect.dis"
    objdump -d -l --section="$sect" "$bin" >"$dis"
    grep -qE '[[:space:]]x[0-9]+,' "$dis" || [[ $sect != __rig_text ]] || fail "bench/$p: no arm64 instructions read from $bin's $sect"
    lines=$(grep -oE '/sched\.zig:[0-9]+' "$dis" | sed 's/.*://' | sort -un)
    for f in $(functions "$ROOT/src/sched.zig" "$lines"); do
        case " $allowed " in
            *" $f "*) ;;
            *) fail "bench/$p: sched.zig's \`$f\` is inlined into the program's section, where a signal may stop it" ;;
        esac
    done
    lines=$(grep -oE '/tasks\.zig:[0-9]+' "$dis" | sed 's/.*://' | sort -un)
    for f in $(functions "$ROOT/src/tasks.zig" "$lines"); do
        case " $apart " in
            *" $f "*) fail "bench/$p: tasks.zig's \`$f\`, which takes a lock uncounted, is inlined into the program's section" ;;
        esac
    done
}

cat > calls.rig <<'RIG'
use std.sort
use std.text
use std.task

obj P
  a: Int
  b: Int

fun work(n: Int) -> Int
  s = 0
  xs: List[Int] = List()
  for i in 0..n
    !xs.push(i * 7 % 1003)
  for i in 0..n
    s += xs[i] % 7 + xs[i] / 3 + xs[(i * 13) % xs.len]
  ys = ?xs[1..n / 2]
  for y in ys
    s += y
  sort.sort_by(!xs[..], |a, b| a % 100 < b % 100)
  m: Map[Int, Int] = Map()
  for i in 0..1000
    !m.put(i, i)
  s += m.len
  hm: HashMap[String, Int] = HashMap()
  !hm.put(String("k"), 1)
  t = String("hello world")
  u = String("hello there")
  for 0..1000
    if t < u
      s += 1
    if t == u
      s += 1
    s += text.width(?t)
  f = |x: Int| x * 3 % 11
  for i in 0..1000
    s += f(i)
  p = P(a: 1, b: 2)
  s += p.a
  fl = 1.5
  for 0..100
    fl = fl * 1.0001 + 0.5
  s += 1 if fl > 2.0 else 0
  s

sub main()
  t = work(10000)&
  print(>t > 0)
RIG

# calls BIN SECTION NAME: every call from BIN's SECTION to a function
# defined outside it is named in test/cli/preempt_calls.txt.
calls() {
    python3 - "$1" "$2" "$ROOT/test/cli/preempt_calls.txt" >"$3.calls" <<'PY' || fail "$3: the program's section calls outside it, unnamed in test/cli/preempt_calls.txt: $(tr '\n' ' ' <"$3.calls")"
import fnmatch, re, subprocess, sys
binary, section, rules = sys.argv[1:4]
allowed = [l.split()[0] for l in open(rules) if l.strip() and not l.startswith("#")]
macho = "mach-o" in subprocess.run(["objdump", "-h", binary], capture_output=True, text=True).stdout.lower()
def name(sym):
    sym = re.sub(r"\+0x[0-9a-f]+$", "", sym).removesuffix("@plt")
    if macho: sym = sym.removeprefix("_")
    return re.sub(r"__func_[0-9]+", "", sym)
inside = set()
for line in subprocess.run(["objdump", "-t", binary], capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if any(t == section or t.endswith("," + section) for t in f[:-1]):
        inside.add(name(f[-1]))
dis = subprocess.run(["objdump", "-d", "-r", "--section=" + section, binary], capture_output=True, text=True).stdout
called = set()
for line in dis.splitlines():
    m = re.search(r"(?:BRANCH26|R_X86_64_PLT32|R_X86_64_PC32)\s+(\S+)", line) or re.search(r"\b(?:bl|call)q?\s+(?:0x)?[0-9a-f]+\s+<([^>]+)>", line)
    if m: called.add(name(m.group(1).split("-")[0]))
bad = sorted(c for c in called - inside if not c.startswith("ltmp") and not any(fnmatch.fnmatchcase(c, a) for a in allowed))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# src NAME: the program built: a bench, or calls.rig.
src() { if [[ $1 == calls ]]; then echo "$PWD/calls.rig"; else echo "$ROOT/bench/$1/$1.rig"; fi; }

for p in tasks actors calls; do
    if [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]]; then
        RIG_OUT_DIR="$PWD/mac-$p" "$RIG" build --release=fast -o "mac-$p.bin" "$(src $p)" >/dev/null 2>build.err ||
            fail "build bench/$p: $(cat build.err)"
        obj="mac-$p/__rig_program-apart.o"
        [[ -f $obj ]] || fail "bench/$p: no object $obj"
        objdump -h "mac-$p.bin" | grep -q ' __rig_text ' || fail "bench/$p: the executable has no __rig_text section"
        check "$obj" __rig_text "$p"
        calls "$obj" __rig_text "mac-$p"
        x15='[[:space:],[](x15|w15)([[:space:],]|]|$)'
        ! grep -qE "$x15" "${p}__rig_text.dis" || fail "bench/$p: the program's section uses x15: $(grep -m1 -E "$x15" "${p}__rig_text.dis")"
        objdump -r --section=__rig_text "$obj" >"$p.relocs"
        ! grep -q TLVP "$p.relocs" || fail "bench/$p: the program's section reads a thread-local: $(grep -m1 TLVP "$p.relocs")"
    fi
    if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
        "$RIG" build --release=fast -o "$p" "$(src $p)" >/dev/null 2>build.err ||
            fail "build bench/$p: $(cat build.err)"
    else
        RIG_OUT_DIR="$PWD/pkg-$p" "$RIG" emit "$(src $p)" >/dev/null 2>build.err ||
            fail "emit bench/$p: $(cat build.err)"
        (cd "pkg-$p" && "$ZIG" build-exe -OReleaseFast -fomit-frame-pointer -fno-stack-protector -target x86_64-linux \
            --cache-dir "$RIG_OUT_DIR/preempt-section-cache" __rig_main.zig -femit-bin="../$p") >build.err 2>&1 ||
            fail "build bench/$p for x86-64 Linux: $(cat build.err)"
    fi
    check "$p" rig_text "$p"
    calls "$p" rig_text "$p"
    ! grep -q '%fs:' "${p}rig_text.dis" || fail "bench/$p: the program's section reads a thread-local: $(grep -m1 '%fs:' "${p}rig_text.dis")"
done
