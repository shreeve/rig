# The wait protocol's Lean model (formal/LambdaRig/Wait.lean) and its
# Zig code (src/sched.zig, `Wait`) in step: the word's numbers, which
# Lean step each Zig function that touches the word is, and the lines
# that make each step. A change to either fails here until the other
# follows; update the table below with both.
source "$ROOT/test/cli/_lib.sh"

zig="$ROOT/src/sched.zig"
lean="$ROOT/formal/LambdaRig/Wait.lean"
[[ -f $zig && -f $lean ]] || fail "missing $zig or $lean"

# body <file> <start-regex>: the lines from the first match of <start-regex>
# to the end of that definition: Zig's closing brace at the same indent,
# or, in Lean, the next line that starts a declaration, a constructor's
# comment, or another constructor.
zbody() { awk -v re="$2" '
    !on && $0 ~ re { on = 1; match($0, /^ */); ind = RLENGTH; print; next }
    on { print; match($0, /^ */); if (RLENGTH == ind && substr($0, ind + 1, 1) == "}") exit }' "$1"; }
lbody() { awk -v re="$2" '
    !on && $0 ~ re { on = 1; print; next }
    on && ($0 ~ /^(def|theorem|inductive|structure|\/--|end|namespace)/ || $0 ~ /^  \/--/ || $0 ~ /^  [|] [a-zA-Z]+ [(]/) { exit }
    on { print }' "$1"; }

lblock() { awk -v re="$2" '!on && $0 ~ re { on = 1 } on && /^$/ { exit } on { print }' "$1"; }

# need <what> <text> <substring>...: each substring is in text.
need() {
    local what=$1 text=$2; shift 2
    [[ -n $text ]] || fail "$what: not found"
    local s
    for s in "$@"; do grep -qF -- "$s" <<<"$text" || fail "$what: lacks [$s]"; done
}

# The numbers: each of Lean's must be Zig's.
num() { sed -n "s/$2/\\1/p" "$1" | head -1; }
z_about=$(num "$zig" '^ *const about = \([0-9][0-9]*\);.*')
z_asleep=$(num "$zig" '^ *const asleep = \([0-9][0-9]*\);.*')
z_woken=$(num "$zig" '^ *const woken = \([0-9][0-9]*\);.*')
z_cancel=$(num "$zig" '^ *const cancelable_bit: u64 = \([0-9][0-9]*\);.*')
z_states=$(num "$zig" '^ *const states: u64 = \([0-9][0-9]*\);.*')
z_shift=$(zbody "$zig" 'fn pack[(]' | sed -n 's/.*@as(u64, epoch) << \([0-9][0-9]*\)).*/\1/p')
z_unshift=$(zbody "$zig" 'fn epochOf[(]' | sed -n 's/.*w >> \([0-9][0-9]*\)).*/\1/p')
l_about=$(num "$lean" '^ *| \.about => \([0-9][0-9]*\)$')
l_asleep=$(num "$lean" '^ *| \.asleep => \([0-9][0-9]*\)$')
l_woken=$(num "$lean" '^ *| \.woken => \([0-9][0-9]*\)$')
l_cancel=$(num "$lean" '^def cancelableBit : Nat := \([0-9][0-9]*\)$')
l_states=$(num "$lean" '^def stateMask : Nat := \([0-9][0-9]*\)$')
l_shift=$(num "$lean" '^def epochShift : Nat := \([0-9][0-9]*\)$')
for n in about asleep woken cancel states shift; do
    z="z_$n"; l="l_$n"
    [[ -n ${!z} ]] || fail "src/sched.zig: no number for $n"
    [[ -n ${!l} ]] || fail "Wait.lean: no number for $n"
    expect_eq "${!z}" "${!l}" "$n in src/sched.zig and Wait.lean"
done
expect_eq "$z_unshift" "$z_shift" "epochOf shifts back as far as pack shifts up"
need "Wait.lean pack" "$(lbody "$lean" '^def pack ')" "e * 2 ^ epochShift" "if c then cancelableBit else 0" "s.code"
need "sched.zig Wait.pack" "$(zbody "$zig" 'fn pack[(]')" "if (cancelable) cancelable_bit else 0" "| state"

# Every Zig function that touches a wait's word, and the Lean step it is
# ("-" for none of its own).
zfns=$(awk '
    /^ *(pub )?(inline |noinline )?fn [a-zA-Z_]+\(/ { s = $0; sub(/^ *(pub )?(inline |noinline )?fn /, "", s); sub(/\(.*/, "", s); cur = s }
    /wait\.word/ { print cur }' "$zig" | sort -u | tr '\n' ' ')
want="beginWait claim fallAsleep fiberMain interrupt interruptForCancel "
expect_eq "$(tr ' ' '\n' <<<"$zfns" | sed '/^$/d' | sort | tr '\n' ' ')" "$want" \
    "the functions of src/sched.zig that touch a wait's word: each must be a step of Wait.lean, listed here"

# Every Lean step, and the Zig it models.
lsteps=$(lblock "$lean" '^inductive Step ' | sed -n 's/^  | \([a-zA-Z]*\) .*/\1/p' | sort | tr '\n' ' ')
expect_eq "$lsteps" "begin claim fallAsleep giveUp interrupt resume " \
    "the steps of Wait.lean: each must match src/sched.zig, listed here"

# begin: beginWait, a new epoch, about to sleep.
need "Wait.lean begin" "$(lbody "$lean" '^  [|] begin ')" "⟨w.epoch + 1, .about, c, .waiting, 0, 0⟩"
need "sched.zig beginWait" "$(zbody "$zig" 'pub fn beginWait[(]')" \
    "f.wait.epoch +%= 1" "Wait.pack(f.wait.epoch, cancelable, Wait.about)" ".seq_cst"

# fallAsleep: about to sleep becomes asleep; a waker came first: queue it.
need "Wait.lean fallAsleep" "$(lbody "$lean" '^  [|] fallAsleep ')" \
    "if w.st = .about then { w with st := .asleep" "queued := w.queued + 1"
for f in 'fn fallAsleep[(]' 'fn fiberMain[(]'; do
    need "sched.zig $f" "$(zbody "$zig" "$f")" \
        "& Wait.states == Wait.about" "& ~Wait.states) | Wait.asleep, .seq_cst, .seq_cst)" "wake("
done

# interrupt: of its epoch only, not a wait woken, a cancel only of a wait
# a cancel may end; it wakes, and queues a fiber asleep.
need "Wait.lean W.interrupt" "$(lbody "$lean" '^def W.interrupt ')" \
    "e = w.epoch" "w.st ≠ .woken" "(cancel = false ∨ w.cancelable = true)" "st := .woken" \
    "if w.st = .asleep then 1 else 0"
need "Wait.lean interrupt" "$(lbody "$lean" '^  [|] interrupt ')" "(w.interrupt e cancel)"
need "sched.zig interrupt" "$(zbody "$zig" 'pub fn interrupt[(]')" \
    "if (Wait.epochOf(w) != epoch) return false;" "if (state == Wait.woken) return false;" \
    "if (cancel and w & Wait.cancelable_bit == 0) return false;" \
    "& ~Wait.states) | Wait.woken, .seq_cst, .seq_cst)" "if (state == Wait.asleep) wake(f);"
need "sched.zig interruptForCancel" "$(zbody "$zig" 'pub fn interruptForCancel[(]')" \
    "interrupt(f, Wait.epochOf(f.wait.word.load(.seq_cst)), true)"

# claim: a wait of its epoch, asleep, becomes woken, run at once.
need "Wait.lean claim" "$(lbody "$lean" '^  [|] claim ')" "e = w.epoch ∧ w.st = .asleep" "st := .woken"
need "sched.zig claim" "$(zbody "$zig" 'fn claim[(]')" \
    "Wait.epochOf(w) == epoch and w & Wait.states == Wait.asleep" "& ~Wait.states) | Wait.woken, .seq_cst, .seq_cst)"

# giveUp and resume touch no word: a wait that finds what it waits for
# goes on, and a fiber queued runs again.
need "Wait.lean giveUp" "$(lbody "$lean" '^  [|] giveUp ')" "{ w with phase := .running }"
need "Wait.lean resume" "$(lbody "$lean" '^  [|] resume ')" "{ w with phase := .running }"
echo "ok"
