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
# (`wakeIn`, `commitWaitIn`, and the rest) may appear. Linux x86-64 only,
# where the option is built.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]] || ! command -v objdump >/dev/null; then
    exit 0
fi

# The functions of sched.zig whose code may sit in the program's section.
allowed="current nowNs seed computed lock unlock lockGraph unlockGraph block unblock leadsOn taken free join waitEnd settleLeftCalls wakeLeft"

for p in tasks actors; do
    RIG_PREEMPT=signal "$RIG" build --release=fast -o "$p" "$ROOT/bench/$p/$p.rig" >/dev/null 2>build.err ||
        fail "build bench/$p with RIG_PREEMPT=signal: $(cat build.err)"
    objdump -h "$p" | grep -q ' rig_text ' || fail "bench/$p has no rig_text section"
    lines=$(objdump -d -l --section=rig_text "$p" | grep -oE 'sched\.zig:[0-9]+' | sed 's/.*://' | sort -un)
    [[ -n $lines ]] || continue
    # Each line's function: the nearest `fn` declaration above it.
    funcs=$(awk -v want="$(tr '\n' ' ' <<<"$lines")" '
        BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) need[w[i]] = 1 }
        /^ *(pub )?(inline |noinline )?fn [A-Za-z_]+/ {
            match($0, /fn [A-Za-z_]+/); name = substr($0, RSTART + 3, RLENGTH - 3)
        }
        NR in need { print name }
    ' "$ROOT/src/sched.zig" | sort -u)
    for f in $funcs; do
        case " $allowed " in
            *" $f "*) ;;
            *) fail "bench/$p: sched.zig's \`$f\` is inlined into the program's section, where a signal may stop it" ;;
        esac
    done
done
