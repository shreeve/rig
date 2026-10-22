#!/usr/bin/env python3
"""Translate variant-A Rig programs into variants B, C and D.

    A  ?x ?T   !x !T   (!v).m()   not x   @size(T)
    B  &x &T   !x !T   (!v).m()   not x   @size(T)
    C  &x &T   @x @T   @v.m()     not x   $size(T)
    D  &x &T   @x @T   @v.m()     !x      $size(T)

Postfix `?` / `!`, `??`, `?.` and `!=` are the same in every variant.

Usage: translate.py SRC_DIR OUT_ROOT   (writes OUT_ROOT/B, OUT_ROOT/C, OUT_ROOT/D)

The work is done on tokens, one line at a time (no Rig token spans lines),
so line numbers never change. A sigil is a prefix exactly where Rig reads
one: when the token before it does not end a value (SYNTAX.md section 5).
"""

import os
import re
import sys

KEYWORDS = {
    "fun", "sub", "struct", "enum", "error", "type", "use", "pub", "extern",
    "test", "drop", "const", "if", "else", "while", "for", "in", "match",
    "break", "continue", "return", "defer", "errdefer", "pass", "and", "or",
    "not", "as", "catch", "raw", "zig", "new", "of",
}
VALUE_WORDS = {"true", "false", "none", "self"}

# Longest first, so `??` is one token and `!=` never yields a prefix `!`.
PUNCT = [
    "<<=", ">>=", "...",
    "==", "!=", "<=", ">=", "??", "->", "=>", "..", "+=", "-=", "*=", "/=",
    "%=", "<<", ">>", "+%", "-%", "*%", "=!",
]

TOKEN_RE = re.compile(
    r"(?P<ws>[ \t]+)"
    r"|(?P<comment>#.*)"
    r'|(?P<str>"(?:\\.|[^"\\])*"|\'(?:\'\'|[^\'])*\')'
    r"|(?P<num>(?:0[xob])?[0-9][0-9a-fA-F_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_]*)"
    r"|(?P<punct>" + "|".join(re.escape(p) for p in PUNCT) + r"|.)"
)

BINARY = {
    "==", "!=", "<", ">", "<=", ">=", "??", "..", "|", "^", "&", "<<", ">>",
    "+", "-", "+%", "-%", "*", "/", "%", "*%",
}


class Tok:
    def __init__(self, kind, text):
        self.kind = kind      # ws, comment, str, num, ident, punct
        self.text = text      # the text written out
        self.orig = text      # the text in variant A
        self.prefix = False   # a prefix sigil (for ? ! - etc.)
        self.infix = False    # a binary operator between two values

    def __repr__(self):
        return f"Tok({self.kind},{self.text!r})"


def tokenize(line):
    toks = []
    pos = 0
    while pos < len(line):
        m = TOKEN_RE.match(line, pos)
        kind = m.lastgroup
        toks.append(Tok(kind, m.group(kind)))
        pos = m.end()
    return toks


def ends_value(t):
    """Whether a token ends a value, so the character after it continues it."""
    if t is None:
        return False
    if t.kind in ("num", "str"):
        return True
    if t.kind == "ident":
        return t.orig not in KEYWORDS or t.orig in VALUE_WORDS
    if t.kind == "punct":
        if t.orig in (")", "]"):
            return True
        if t.orig in ("?", "!") and not t.prefix:
            return True   # a postfix ? or !
    return False


def classify(toks):
    """Mark prefix sigils and infix operators."""
    prev = None       # previous significant token
    prev_prev = None
    for i, t in enumerate(toks):
        if t.kind in ("ws", "comment"):
            continue
        if t.kind == "punct":
            if ends_value(prev):
                # `[]?T`, `[4]!T`: a sigil touching a type after an array's `]`.
                nxt = toks[i + 1] if i + 1 < len(toks) else None
                if (t.orig in ("?", "!") and prev.orig == "]"
                        and nxt is not None and nxt.kind == "ident"
                        and prev_prev is not None
                        and (prev_prev.orig == "[" or prev_prev.kind == "num")):
                    t.prefix = True
                elif t.orig in BINARY:
                    t.infix = True
            else:
                t.prefix = True
        prev_prev, prev = prev, t


def sig(toks, i, step=1):
    """Index of the next significant token from i (exclusive) in a direction."""
    j = i + step
    while 0 <= j < len(toks) and toks[j].kind in ("ws",):
        j += step
    return j if 0 <= j < len(toks) else None


def rewrite_write_call(toks):
    """`(!place).m(` -> `@place.m(`: drop the parentheses around a write lend
    whose place a method call follows. The `(` must start an operand (it is
    not a call's own parenthesis)."""
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.kind == "punct" and t.orig == "(" and t.prefix:
            j = i + 1
            if j < len(toks) and toks[j].orig == "!" and toks[j].prefix:
                # a place: name, then .field or [index] steps, then `)`
                k = j + 1
                if k < len(toks) and toks[k].kind == "ident":
                    k += 1
                    ok = True
                    while k < len(toks) and toks[k].orig in (".", "["):
                        if toks[k].orig == ".":
                            k += 2
                        else:
                            depth = 0
                            while k < len(toks):
                                if toks[k].orig == "[":
                                    depth += 1
                                elif toks[k].orig == "]":
                                    depth -= 1
                                    if depth == 0:
                                        break
                                k += 1
                            k += 1
                    if (ok and k + 2 < len(toks) and toks[k].orig == ")"
                            and toks[k + 1].orig == "." and toks[k + 2].kind == "ident"):
                        toks[i].text = ""      # drop `(`
                        toks[k].text = ""      # drop `)`
        i += 1


STOP_WORDS = {"and", "or", "if", "else", "catch", "as"}
STOP_PUNCT = {",", ")", "]", "=>", "=", "+=", "-=", "*=", "/=", "%="}


def rewrite_not(toks):
    """`not x` -> `!x`, parenthesizing an operand that holds a binary operator."""
    for i, t in enumerate(toks):
        if not (t.kind == "ident" and t.orig == "not"):
            continue
        # The operand runs to the first stop at bracket depth 0.
        j = i + 1
        while j < len(toks) and toks[j].kind == "ws":
            j += 1
        start = j
        depth = 0
        needs_parens = False
        end = start
        k = start
        while k < len(toks):
            tk = toks[k]
            if tk.kind == "comment":
                break
            if depth == 0 and (
                (tk.kind == "ident" and tk.orig in STOP_WORDS)
                or (tk.kind == "punct" and tk.orig in STOP_PUNCT)
            ):
                break
            if tk.orig in ("(", "["):
                depth += 1
            elif tk.orig in (")", "]"):
                depth -= 1
            elif depth == 0 and tk.infix:
                needs_parens = True
            if tk.kind != "ws":
                end = k
            k += 1
        t.text = "!"
        # drop the space after `not`
        for w in range(i + 1, start):
            toks[w].text = ""
        if needs_parens:
            toks[start].text = "(" + toks[start].text
            toks[end].text = toks[end].text + ")"


def translate_line(line, variant):
    toks = tokenize(line)
    classify(toks)
    if variant in ("C", "D"):
        rewrite_write_call(toks)
    for i, t in enumerate(toks):
        if t.kind != "punct":
            continue
        if t.orig == "?" and t.prefix:
            t.text = "&"
        elif t.orig == "!" and t.prefix and variant in ("C", "D"):
            t.text = "@"
        elif t.orig == "@" and variant in ("C", "D"):
            t.text = "$"
    if variant == "D":
        rewrite_not(toks)
    return "".join(t.text for t in toks)


def translate(src, variant):
    out = []
    for line in src.split("\n"):
        if "#" in line and any(t.kind == "comment" for t in tokenize(line)):
            sys.stderr.write(f"warning: comment left untranslated: {line.strip()}\n")
        out.append(translate_line(line, variant))
    return "\n".join(out)


def main():
    src_dir, out_root = sys.argv[1], sys.argv[2]
    for variant in ("B", "C", "D"):
        out_dir = os.path.join(out_root, variant)
        os.makedirs(out_dir, exist_ok=True)
        for name in sorted(os.listdir(src_dir)):
            if not name.endswith(".rig"):
                continue
            with open(os.path.join(src_dir, name)) as f:
                src = f.read()
            with open(os.path.join(out_dir, name), "w") as f:
                f.write(translate(src, variant))


if __name__ == "__main__":
    main()
