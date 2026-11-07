#!/usr/bin/env bash
# RIG_PREEMPT=signal keeps the scheduler's code out of the program's own
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
# `programCounter` reads the address of its own instruction, nothing
# else, where a List's `push` asks `settleAt` whether it is in the section.
allowed="current nowNs seed computed lock unlock lockGraph unlockGraph block unblock leadsOn taken free join waitEnd settleLeftCalls wakeLeft programCounter"
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

for p in tasks actors; do
    if [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]]; then
        RIG_OUT_DIR="$PWD/mac-$p" RIG_PREEMPT=signal "$RIG" build --release=fast -o "mac-$p.bin" "$ROOT/bench/$p/$p.rig" >/dev/null 2>build.err ||
            fail "build bench/$p with RIG_PREEMPT=signal: $(cat build.err)"
        obj="mac-$p/__rig_program-apart.o"
        [[ -f $obj ]] || fail "bench/$p: no object $obj"
        objdump -h "mac-$p.bin" | grep -q ' __rig_text ' || fail "bench/$p: the executable has no __rig_text section"
        check "$obj" __rig_text "$p"
        x15='[[:space:],[](x15|w15)([[:space:],]|]|$)'
        ! grep -qE "$x15" "${p}__rig_text.dis" || fail "bench/$p: the program's section uses x15: $(grep -m1 -E "$x15" "${p}__rig_text.dis")"
        objdump -r --section=__rig_text "$obj" >"$p.relocs"
        ! grep -q TLVP "$p.relocs" || fail "bench/$p: the program's section reads a thread-local: $(grep -m1 TLVP "$p.relocs")"
    fi
    if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
        RIG_PREEMPT=signal "$RIG" build --release=fast -o "$p" "$ROOT/bench/$p/$p.rig" >/dev/null 2>build.err ||
            fail "build bench/$p with RIG_PREEMPT=signal: $(cat build.err)"
    else
        RIG_OUT_DIR="$PWD/pkg-$p" RIG_PREEMPT=signal "$RIG" emit "$ROOT/bench/$p/$p.rig" >/dev/null 2>build.err ||
            fail "emit bench/$p with RIG_PREEMPT=signal: $(cat build.err)"
        (cd "pkg-$p" && "$ZIG" build-exe -OReleaseFast -fomit-frame-pointer -fno-stack-protector -target x86_64-linux \
            --cache-dir "$RIG_OUT_DIR/preempt-section-cache" __rig_main.zig -femit-bin="../$p") >build.err 2>&1 ||
            fail "build bench/$p for x86-64 Linux with RIG_PREEMPT=signal: $(cat build.err)"
    fi
    check "$p" rig_text "$p"
    ! grep -q '%fs:' "${p}rig_text.dis" || fail "bench/$p: the program's section reads a thread-local: $(grep -m1 '%fs:' "${p}rig_text.dis")"
done
