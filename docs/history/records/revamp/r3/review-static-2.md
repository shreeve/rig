# Review of PR #105 (Static), a204f003: can a view of an owner get type Static?

Verdict: no hole found. About 75 probes (about 55 distinct programs after syntax fixes), built in a detached worktree (removed afterwards).

Every program that put a Text view toward a Static was rejected with "expected Static, got String" or a Cell-view error:
generic inference (T from String arg, either argument order, mixed with Cell[T]), Static var / Static? / [N]Static / struct and generic-struct field reassigned from a String, Static-typed binding of a Text slice, `-> Static` returning a view of a ?Text param, `??` / `catch` / if-else / match mixing, list literals, `[]Static` and Vec[Static] from Text slices, closures (owned and plain) returning Strings where Static is expected, module constants, os.env / os.args mixed with views, function-type and !Static/?Static/Cell[Static] variance.

Accepted and run clean (debug and --release, RIG_SANITIZE=1): literal-only programs (literal closure capture, slices of a literal in a Cell, `s: String = "x"` in a Cell, loops over Text), all correct output.

Conservative rejections (not soundness): `s: String = "x"` into Cell[Static], and a module constant declared String, are rejected.
