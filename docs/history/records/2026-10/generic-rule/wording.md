# The generic-value rule: wording for the owner (2026-10-27)

Three experts (soundness and Core, compiler and oracle, adversary) reviewed the problem in [problem.md](problem.md). Their reports are `expert-*.md` beside this file, and their probes are in `*-probes/`, all run under `RIG_SANITIZE=1`. They agree on the rule below.

## The hole
A generic body assumes that a value of a type parameter it holds itself (a local, a by-value parameter, an element or field of self's storage) holds no view, so it tracks none. At an instance whose type argument can hold a view, such a value can be given one that outlives what it views. Each of these is accepted today and reads freed memory:
- Map's `update`, `retain`, and `ensure_with(k, |k| k)`, the last through its result;
- a program's own generic method or function, through a field, an element or a local;
- a `*sub` value, a named function declared `keeps`, forwarding through another generic, and two write views (`f(!@a, !@b)`);
- a method of the type argument whose result views its self;
- through an API object, `Wrap[List[?String]]`, an enum payload, `((?String)?)?`, or a by-value parameter.

The same programs written without generics are rejected.

## The rule (SPEC "Generic bodies"; CORE unchanged)
It replaces "A `T` the body holds by value carries no loans it tracks, so an instance whose method keeps an argument's view in one (`keeps`) is refused" with:

> A `T` the body holds by value, in a local, a parameter it owns, or self's storage, carries no loans it tracks. So wherever the body could put a view into one, its type argument must hold no view. That happens where a method of the instance keeps an argument's view in it, or gives a result that views its self or an argument (as its `from` says). It happens where a function value is given a write view of one beside another view, read or write. And it happens where the body holds as one a function value's result from a call given a view. An instance whose type argument can hold a view, one that is not `Owned`, is refused at the call or type that makes it, with a note at the body line. A view the body was lent stays tracked as any lent view is.

**Built as:**
- one classifier, the per-instance requirement Cells already use (`requireNoView`, checked by `checkViews`), keyed by `sema.defaultOrigins` of the callable type at the instance;
- the built-in table's `update`, `retain` and `insert_new` declare it;
- the oracle gets the same instance rule.

About 110 lines in the compiler and 30 in the oracle. Emit is untouched.

## Cost
- **Trig:** no refusals.
- **std:** `Map.update`, `retain` and `ensure_with` at a value type that can hold a view (`Map[String, (?String)?]`, `Map[String, List[?String]]`) are refused, even with a harmless closure. Use an owned value type, or walk `items`.
- **Tests:** one probe (probes-16 "rev240-m03") is refused, and one case's error count changes.
- **Release notes:** these list the newly refused forms. Trig gets a one-line note; it needs no migration.

## Decisions (defaults first)
1. **Take the rule above.** [yes]
2. **Widen #737's "no parameter is a `!?String`" to any `!?T`.** That also fixes the `!?List[Int]` closure `.len` emit failure: emit strips one pointer of two. About 6 lines. [yes]
3. **Drop `ensure_with`'s `keeps make` once the rule lands.** It only compiles today because of a checker leniency the soundness expert found. [yes]
4. **Defer the refinement that accepts harmless closures,** checking a literal closure's body per call. [defer]
