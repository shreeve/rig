# The five decisions of the compiler revamp's phase 1: panel and outcome (2026-11-04)

The owner called the five decisions in owner-decisions.md close calls. He
asked for three experts, on Rust, Zig, and Swift/Ruby language design, to
review the lead's recommendations independently. If all three agreed, the
defaults were approved; if any disagreed, the item went back to him.

The brief is panel-brief.md, and the reports are panel-rust.md,
panel-zig.md, and panel-designer.md.

All three agreed on all five, so the owner's instruction approved every
default:

1. **A sigil on a `for` source that is a call goes to the call's self,**
   as everywhere else. The loop's mode comes from the result's type, and
   `for x in !xs` keeps its meaning for a place. Rust's condition: a form
   main accepts whose meaning would change is rejected with a fix, never
   silently changed.
2. **`collect` of views is allowed, with no copy.** The designer's
   condition, which is QUICK.md's existing rule: a chain or `find` whose
   bound result keeps its source lent is written with the mark,
   `vs = ?names.filter(f).collect()`.
3. **bench/check/guard.py is a merge gate for compiler changes,** within
   2% of the committed baseline (Rust's point: against the baseline, not
   the parent), and `--update` gives its reason (all three).
4. **A check-speed round after phase 2,** measured on Trig's real check,
   with a budget for each pass (Zig).
5. **Two write captures of one value in a `select` stay rejected.** The
   error shows the rewrite. The better form for later, from all three: a
   `select` that takes the write loan once and hands it to the arm that
   runs (ROADMAP).
