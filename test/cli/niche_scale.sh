# An optional of an object holds `none` in the object's niche, which
# `nicheOf` finds by passing over each of an enum's variants and each of
# an object's fields. Zig evaluates an object's field types and defaults
# outside any function, so that search sets its own compile-time budget:
# an enum of 2300 variants, and an object of 2300 fields, each held in
# an optional field (alone, nested, in a List, in an array, with a
# default), build and run.
source "$ROOT/test/cli/_lib.sh"

n=2300
{
  printf 'enum Big\n'
  for ((i = 0; i < n; i++)); do printf '  v%d\n' $i; done
  printf '\nobj Holder\n  big: Big\n  names: List[String] = List()\n'
  printf '\nobj Wide\n'
  for ((i = 0; i < n; i++)); do printf '  f%d: Bool = false\n' $i; done
  printf '\nobj Outer\n  alt: Holder? = none\n  deep: (Holder?)? = none\n  hs: List[Holder?] = List()\n  three: [3]Holder?\n  w: Wide? = none\n  b: Big? = none\n  count: Int = 0\n'
  printf '\nsub main()\n  o = Outer(three: [none, none, none])\n  !o.hs.push(none)\n  o.alt = Holder(big: Big.v%d)\n  o.w = Wide()\n  if o.alt as h\n    print(h.big)\n  print(o.deep == none, o.hs.len, o.three[2] == none, o.w != none, o.b, o.count)\n' $((n - 1))
} >wide.rig

out=$(rig run wide.rig 2>&1); expect_rc $? 0 "rig run wide.rig: $out"
expect_eq "$out" ".v$((n - 1))
true 1 true true none 0" "an enum and an object of $n parts, held in optional fields"
