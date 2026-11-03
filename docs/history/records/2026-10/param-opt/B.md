# PR #688 panel, adversary B (captures, closures, tasks, generics, classifier)

Head 9ea69ee13 built in ~/Data/Code/worktrees/rig/panel688b; compared with
span-type bin/rig (before #688). All runs RIG_SANITIZE=1, RIG_OUT_DIR temp.
Probes: /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/1762ad8a-9823-467a-b54f-a392863cb42c/scratchpad/p688b/*.rig (runall.sh).

## Classifier
One classifier: sema.moveSource -> fieldSource -> fixedOwner; storage.consumeField
asks moveSource; ownership/typecheck consult it. fixedOwner mirrors
typecheck.requireBinding exactly for take: param/capture not a write view,
local fixed and not pattern/as bound; the member walk rejects every type that
sets Place.indirect (read/write view, shared, slice) plus weak, string_view,
optional, read-only and named-none fields. generic_param kind falls to false.
So the new path fires only where the take was rejected; no take that was
accepted becomes a move. Oracle `unassignable` agrees (via == .own, !handle).

## Same on both (take kept, identical output)
b_wcap `|!p|` (2 0 / true ab); g1 path capture `|!o.inner|`; j_wparam `p: !Pair`;
j_wmethod `!@` (0 true); k_defer_w defer through `!p`; h_for `for x in <v`;
h_forw `for x in !v`; h_ifas / h_ifas_param `if <o as s`; h_match / h_match_param
`match <x`; l_pathlocal `|<p.tags|` of an assignable local (3 true ab);
n_copylocal. Read captures/views still rejected (a_rcap, l_once_capture_name_after).

## Newly accepted, correct output, sanitizer clean
d_clone 5, f2 path move once 5, g2 nested path once 5, i_fixed_cond/loop,
j_wmethod `<@` 2, k_defer_after/cond, l_once_twice 5, l_once_inner_field 6,
m_gen (T=String, Int, List?, `!Two[T]` takes) , o_cond_drop 2 3 2,
o_disjoint_path 4, q_maybe (once closure not called) 4 0, q_task_body 4 4, t2_task 4.

## Correctly rejected
Many-call: e_owned `*|<p|`, f3 `|<p.tags|` twice, o_many_param, o_once_named,
q_clone_many, l_nested_once. Loops: l_once_loop, o_once_loop2. Defers:
k_defer_fixed, o_once_defer. Tasks: t1 (read after), t3 (lend after), t4 (move
under task's live read loan), t5 (whole after), o_once_task. Loans: o_loan_before(2).
Whole after partial: i_fixed_whole, l_once_partial_then_capture, m_gen_rej.

## Findings
1. (low, consistency) m_gen_copy: `fun g1[T: Copy](p: Two[T]) -> T?  <p.val`
   is now accepted (prints 3) while concrete `Int?` stays rejected ("cannot take
   parameter", PR's own copies case). Cause: sema.copies(T?) for a Copy-bound T is
   .depends (moves(T?)), not .yes, so fixedOwner moves it. Not unsound (a move of
   a copy), but the rule "an optional that copies is not moved" differs between
   generic and concrete. Fix: have copies() look through optional for a Copy
   bound, or accept the concrete case too.
2. (nit, pre-existing) `|+p| <p.f` says "write `+p` for a clone" though it is
   already `+p` (same on main for a non-optional field).

Verdict: sound.
