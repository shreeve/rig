# Brief: one short name for "how many characters a reader sees"

Rig (a systems language; readability of Python and Ruby, the safety of
Rust, the cost model of Zig) needs ONE short, easy-to-type name for the
number of grapheme clusters (UAX #29, what Swift's `String.count` counts)
in a string. The owner finds `text.grapheme_count(s)` / `s.grapheme_count()`
too long to type. This is decided once and never changed.

## Fixed context
- `s.len` = bytes, stored (a field, instant).
- `size` = space ONE thing takes (`utf8.size(r)` bytes of one rune; `Rune.size`).
- Counts that scan are calls with parentheses and name their unit:
  `utf8.rune_count(s)`, `utf16.unit_count(s)`.
- `text.count(s, pat)` already counts occurrences of a pattern (like Go
  `strings.Count`, Python `str.count`) and stays. So bare `count` is taken.
- Vocabulary: byte, rune (a code point), unit (UTF-16), grapheme. The word
  "char" is avoided because C, Java/JS and Rust each mean a different
  thing by it. (An exception is allowed if it is clearly the best answer.)
- Naming rules: queries name their answer; avoid words other languages
  disagree on; the name says which unit; least surprise for a newcomer
  from Python, JS, Ruby, Swift, Go, Rust.
- It scans (O(n)) and depends on the Unicode version; that must stay
  visible (a call with parentheses).
- Typical use: `if post.X() > 280`, `pad(name, 20 - name.X())`,
  showing "12 characters" in a UI.

## The question
Propose the single best short name. Candidates to weigh (add your own):
`glyphs()`, `graphemes()` (as a count? or the iterator?), `letters()`,
`chars()`, `characters()`, `length()`, `glen()`, `gcount()`,
`visible()`, `symbols()`, `clusters()`, `width()` (careful: display
width is a different thing), `char_count()`, `n_chars()`.
