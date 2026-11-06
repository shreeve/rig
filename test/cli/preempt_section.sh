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
# Preemption is built for Linux x86-64. There the benches are built as
# `rig build` builds them; elsewhere `rig emit` writes their package and
# Zig compiles it for x86-64 Linux, with `rig build --release=fast`'s
# flags. An LLVM `objdump` reads either.
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

for p in tasks actors; do
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
    objdump -h "$p" | grep -q ' rig_text ' || fail "bench/$p has no rig_text section"
    objdump -d -l --section=rig_text "$p" >"$p.dis"
    ! grep -q '%fs:' "$p.dis" || fail "bench/$p: the program's section reads a thread-local: $(grep -m1 '%fs:' "$p.dis")"
    lines=$(grep -oE '/sched\.zig:[0-9]+' "$p.dis" | sed 's/.*://' | sort -un)
    for f in $(functions "$ROOT/src/sched.zig" "$lines"); do
        case " $allowed " in
            *" $f "*) ;;
            *) fail "bench/$p: sched.zig's \`$f\` is inlined into the program's section, where a signal may stop it" ;;
        esac
    done
    lines=$(grep -oE '/tasks\.zig:[0-9]+' "$p.dis" | sed 's/.*://' | sort -un)
    for f in $(functions "$ROOT/src/tasks.zig" "$lines"); do
        case " $apart " in
            *" $f "*) fail "bench/$p: tasks.zig's \`$f\`, which takes a lock uncounted, is inlined into the program's section" ;;
        esac
    done
done
