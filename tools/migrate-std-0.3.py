#!/usr/bin/env python3
"""Rewrite a program's uses of the standard library's names that Rig
0.3.0 changed (CHANGELOG, "Upgrading from v0.2.9"):

  std.json    `json.new_doc()` -> `json.Doc()`, and a new Doc tested at
              once, `doc = json.new_doc()` then `if not (!doc).parse(s)`
              with a block that leaves, or `return x if not
              (!doc).parse(s)`, -> `doc = json.parse(s) catch |_|` with
              the block, or `doc = json.parse(s) catch return x`;
              `doc.get_int(i)`, `get_str`, `get_bool`, `get_float` ->
              `doc.int(i)`, `string`, `bool`, `float`; `doc.size()` ->
              `doc.len` for a Doc the file names (bound to a new Doc, or
              a parameter of type `json.Doc`).
  compare     `text.compare(a, b) < 0` -> `a.order(?b) == .less`, and a
              BigInt's `a.compare(b) > 0` -> `a.order(b) == .greater`
              (each comparison with 0 has its `Order`); a result bound to
              a name, `c = a.compare(b)`, whose every use in its function
              compares it with 0, is rewritten with its uses.
  bigint      `a.equals(b)` -> `a == b` (`not a.equals(b)` -> `a != b`),
              `a.to_f64()` -> `a.to_float()`.
  math        `math.powf(x, y)` -> `math.pow(x, y)`, an integer literal
              there written as a float literal, `2` -> `2.0`.
  iter        `iter.count(!it)` -> `(!it).count()`, `iter.sum(!it) ?? 0`
              -> `(!it).sum()`, and `use std.iter` goes once nothing
              names it.
  search      a needle moved or cloned into `slices.contains`,
              `slices.index_of`, `sort.lower_bound`, or `sort.search`,
              `<s` or `+s`, is lent, `?s`, and so is a branching one,
              `?(a if c else b)`.

A module used under another name (`use std.text as stdtext`) is found by
that name. The BigInt rewrites run only in a file that uses std.bigint
and declares no method of the same name itself, and the json getters in
a file that uses std.json. The tool reads no types: in such a file, a
`.equals(`, `.compare(`, `.to_f64(`, or `.get_int(` of a type of
another module that has a method of that name is rewritten too, so read
its diff (`--dry-run`) where such a type is used. Strings and comments
are never changed.

Each site no rewrite fits is printed `MANUAL path:line: why`: a parse
whose result is used otherwise, a Doc's `error` or `error_pos`,
`json.error_name`, a `compare` result used as an `Int`, an `iter.sum`
whose `none` is used or whose `?? 0` has more after it, a `powf` of
arguments not visibly Floats, a `-` before a `compare`, and a
```` ```rig reject ```` block, which may show an old name rejected on
purpose. A second run changes nothing.

usage: tools/migrate-std-0.3.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.tmpl,
  .rig.test, and .md files; in Markdown only ```rig blocks change. It
  prints each file it changes with its count of rewrites, then the
  MANUAL lines and the totals.
"""
import os, re, sys

USE = re.compile(r"^\s*use\s+std\.(json|text|bigint|math|iter|slices|sort)(?:\s+as\s+(\w+))?\s*$")
FENCE = re.compile(r"^(\s*)```")
CMP = {"<": ("==", "less"), ">": ("==", "greater"), "==": ("==", "equal"),
       "!=": ("!=", "equal"), "<=": ("!=", "greater"), ">=": ("!=", "less")}
FLIP = {"<": ">", ">": "<", "<=": ">=", ">=": "<=", "==": "==", "!=": "!="}
SIMPLE = re.compile(r"^[@\w.\[\]]+$")


def code_mask(line):
    """The indexes of `line` that are code: not in a string or a comment."""
    mask = [True] * len(line)
    i, q = 0, None
    while i < len(line):
        c = line[i]
        if q:
            mask[i] = False
            if c == "\\":
                if i + 1 < len(line):
                    mask[i + 1] = False
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
            mask[i] = False
        elif c == "#":
            for j in range(i, len(line)):
                mask[j] = False
            break
        i += 1
    return mask


def closing(s, i):
    """The index of the bracket closing the one at `i`, or -1."""
    depth, q = 0, None
    j = i
    while j < len(s):
        c = s[j]
        if q:
            if c == "\\":
                j += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def split_args(s):
    """The top-level comma-separated parts of `s`."""
    parts, depth, q, start = [], 0, None, 0
    j = 0
    while j < len(s):
        c = s[j]
        if q:
            if c == "\\":
                j += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(s[start:j].strip())
            start = j + 1
        j += 1
    parts.append(s[start:].strip())
    return parts


def receiver_start(s, end):
    """Where the expression ending just before `end` starts: a name,
    `@`, paths, calls, and indexes, with a lend before them."""
    j = end
    while j > 0:
        c = s[j - 1]
        if c in ")]":
            depth = 0
            k = j - 1
            while k >= 0:
                if s[k] in ")]":
                    depth += 1
                elif s[k] in "([":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            if k < 0:
                return -1
            j = k
        elif c.isalnum() or c in "_.@":
            j -= 1
        else:
            break
    if j > 0 and s[j - 1] in "?!" and (j == 1 or not (s[j - 2].isalnum() or s[j - 2] in "_)]")):
        j -= 1
    return j if j < end else -1


def is_float(x):
    """Whether `x` is visibly a Float: a float literal, or a `Float(...)`
    or `Float.` member."""
    return bool(re.match(r"^-?[\d_]+(\.[\d_]+)?([eE][-+]?\d+)?$", x) and re.search(r"[.eE]", x)) or x.startswith("Float(") or x.startswith("Float.")


def flat(x):
    """`x` with what its brackets hold taken out: `a[i - 1].b(c)` is
    `a[].b()`."""
    out, depth = [], 0
    for c in x:
        if c in "([":
            if depth == 0:
                out.append(c)
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth == 0:
                out.append(c)
        elif depth == 0:
            out.append(c)
    return "".join(out) if depth == 0 else " "


def is_path(x):
    """A name, `@`, fields, and indexes: what a lend is written on."""
    return bool(SIMPLE.match(flat(x))) and "(" not in flat(x)


def as_receiver(a):
    if a.startswith("?") and is_path(a[1:]):
        return a[1:]
    if is_path(a) or re.match(r'^"[^"]*"$', a) or re.match(r"^[@\w.\[\]()]+$", flat(a)):
        return a
    return "(%s)" % a


def as_view(b):
    if b.startswith("?") or b.startswith('"'):
        return b
    if is_path(b):
        return "?" + b
    return b


class Unit:
    """One program's text: a file, or a Markdown block."""

    def __init__(self, path, first, lines):
        self.path, self.first, self.lines = path, first, lines
        # Each line's index in the text as it was read, for MANUAL lines.
        self.origin = list(range(len(lines)))
        self.n = 0
        self.manual = []
        self.names = {}
        for ln in lines:
            m = USE.match(ln)
            if m:
                self.names.setdefault(m.group(1), set()).add(m.group(2) or m.group(1))

    def where(self, i):
        return "%s:%d" % (self.path, self.first + self.origin[i] + 1)

    def note(self, i, why):
        self.manual.append("MANUAL %s: %s" % (self.where(i), why))

    def mods(self, mod):
        return self.names.get(mod, set())

    def declares(self, method):
        pat = re.compile(r"^\s*(pub\s+)?fun\s+(\w+\.)?%s\(" % method)
        return any(pat.match(ln) for ln in self.lines)

    def sub(self, pattern, repl, i):
        """`re.sub` on line `i`'s code."""
        line = self.lines[i]
        mask = code_mask(line)
        out, last, k = [], 0, 0
        for m in re.finditer(pattern, line):
            if m.start() >= len(mask) or not mask[m.start()]:
                continue
            r = repl(m) if callable(repl) else m.expand(repl)
            if r is None:
                continue
            out.append(line[last:m.start()])
            out.append(r)
            last = m.end()
            k += 1
        if k:
            out.append(line[last:])
            self.lines[i] = "".join(out)
            self.n += k
        return k

    # ---- passes --------------------------------------------------------

    def run(self):
        if self.mods("json"):
            self.json()
        if self.mods("text"):
            for t in self.mods("text"):
                self.compares(re.escape(t) + r"\.compare\(", text_form=True)
        if self.mods("bigint"):
            self.bigint()
        for m in self.mods("math"):
            self.powf(m)
        if self.mods("iter"):
            self.iter()
        self.needles()

    def powf(self, m):
        """`math.powf(x, y)` -> `math.pow(x, y)`. powf took Floats, so an
        integer literal there was a Float; `pow` would take it as an
        `Int`, so it is written as a float literal. When neither argument
        is then visibly a Float, `pow` could be an Int's: MANUAL."""
        for i in range(len(self.lines)):
            at = 0
            while True:
                line = self.lines[i]
                mask = code_mask(line)
                h = next((mm for mm in re.finditer(r"\b%s\.powf\(" % re.escape(m), line) if mm.start() >= at and mask[mm.start()]), None)
                if not h:
                    break
                at = h.end()
                close = closing(line, h.end() - 1)
                args = split_args(line[h.end():close]) if close > 0 else []
                if len(args) != 2:
                    self.note(i, "`%s.powf` with other than two arguments on one line: write `%s.pow` with Float arguments" % (m, m))
                    continue
                args = [a + ".0" if re.match(r"^-?[\d_]+$", a) else a for a in args]
                if not any(is_float(a) for a in args):
                    self.note(i, "`%s.powf(x, y)` of arguments not visibly Floats: write `%s.pow(x, y)` once each is a Float (a literal `2.0`, or `Float(n)`), since `pow` of two Ints is an Int's" % (m, m))
                    continue
                self.lines[i] = line[:h.start()] + "%s.pow(%s)" % (m, ", ".join(args)) + line[close + 1:]
                self.n += 1

    def json(self):
        js = self.mods("json")
        alt = "|".join(re.escape(j) for j in js)
        docs = set()
        for ln in self.lines:
            for m in re.finditer(r"\b(\w+)\s*=\s*(?:%s)\.(?:new_doc|Doc|parse)\(" % alt, ln):
                docs.add(m.group(1))
            for m in re.finditer(r"\b(\w+)\s*:\s*[?!]?(?:%s)\.Doc\b" % alt, ln):
                docs.add(m.group(1))
        i = 0
        while i < len(self.lines):
            m = re.match(r"^(\s*)(\w+)\s*=\s*(%s)\.new_doc\(\)\s*$" % alt, self.lines[i])
            if m and code_mask(self.lines[i])[len(m.group(1))]:
                self.collapse(i, m.group(1), m.group(2), m.group(3))
            i += 1
        for i in range(len(self.lines)):
            for j in js:
                self.sub(r"\b%s\.new_doc\(\)" % re.escape(j), j + ".Doc()", i)
            for old, new in (("get_int", "int"), ("get_str", "string"), ("get_bool", "bool"), ("get_float", "float")):
                self.sub(r"\.%s\(" % old, "." + new + "(", i)
            for d in docs:
                self.sub(r"\b%s\.size\(\)" % re.escape(d), d + ".len", i)
            mask = code_mask(self.lines[i])
            for pat, why in ((r"\b(?:%s)\.error_name\(" % alt, "`json.error_name` is gone: a `JsonError` names its reason and offset (`print(e)`, `match e` with `.eof(at)`)"),
                             (r"\bJsonError\.bad\b|\.bad\(kind", "`JsonError.bad(kind:, at:)` is a member per reason, each with `at`: `.eof(at)`"),
                             (r"\b(?:%s)\.(?:error|error_pos)\b" % "|".join(re.escape(d) for d in docs) if docs else r"(?!x)x", "a Doc's `error` and `error_pos` are gone: `json.parse` and `load` fail with a `JsonError` carrying the offset"),
                             (r"\(!(?:%s)\)\.parse\(" % "|".join(re.escape(d) for d in docs) if docs else r"(?!x)x", "`(!doc).parse(s)` answering a Bool is gone: `doc = json.parse(s)!`, or `(!doc).load(s)!` to fill a Doc again")):
                for mm in re.finditer(pat, self.lines[i]):
                    if mask[mm.start()]:
                        self.note(i, why)
                        break

    def collapse(self, i, ind, d, j):
        """`d = json.new_doc()` at line `i`, and the line after it."""
        k = i + 1
        while k < len(self.lines) and not self.lines[k].strip():
            k += 1
        if k >= len(self.lines):
            return
        nxt = self.lines[k]
        m = re.match(r"^%sreturn (.+) if not \(!%s\)\.parse\((.*)\)\s*$" % (re.escape(ind), re.escape(d)), nxt)
        if m and closing(nxt, nxt.index("(!%s).parse(" % d) + len("(!%s).parse" % d)) == len(nxt.rstrip()) - 1:
            self.lines[i] = "%s%s = %s.parse(%s) catch return %s" % (ind, d, j, m.group(2), m.group(1))
            del self.lines[k]
            del self.origin[k]
            self.n += 1
            return
        m = re.match(r"^%sif not \(!%s\)\.parse\((.*)\)\s*$" % (re.escape(ind), re.escape(d)), nxt)
        if not m:
            return
        body, e = [], k + 1
        while e < len(self.lines) and (not self.lines[e].strip() or len(self.lines[e]) - len(self.lines[e].lstrip()) > len(ind)):
            body.append(self.lines[e])
            e += 1
        stmts = [b.strip() for b in body if b.strip() and not b.strip().startswith("#")]
        if not stmts or not re.match(r"^(return|break|continue|panic\()", stmts[-1]):
            return
        if any(re.search(r"\b%s\.error|error_name\(" % re.escape(d), b) for b in body):
            return
        self.lines[i] = "%s%s = %s.parse(%s) catch |_|" % (ind, d, j, m.group(1))
        del self.lines[k]
        del self.origin[k]
        self.n += 1

    def compares(self, head, text_form):
        """Each `compare` call `head` starts: `text.compare(` or, with
        `text_form` false, a BigInt's `.compare(`."""
        modules = set().union(*self.names.values()) if self.names else set()
        i, at = 0, 0
        while i < len(self.lines):
            line = self.lines[i]
            mask = code_mask(line)
            m = None
            for mm in re.finditer(head, line):
                if mm.start() < at or not mask[mm.start()]:
                    continue
                if not text_form:
                    r = receiver_start(line, mm.start())
                    if r >= 0 and line[r:mm.start()] in modules:
                        continue
                m = mm
                break
            if not m:
                i, at = i + 1, 0
                continue
            at = m.end()
            open_at = m.end() - 1
            close = closing(line, open_at)
            if close < 0:
                self.note(i, "a `compare` call over several lines: write `a.order(?b)`")
                continue
            args = split_args(line[open_at + 1:close])
            if text_form:
                if len(args) != 2:
                    self.note(i, "`text.compare` with other than two arguments")
                    continue
                call = "%s.order(%s)" % (as_receiver(args[0]), as_view(args[1]))
                start = m.start()
            else:
                call = ".order(%s)" % line[open_at + 1:close]
                start = m.start()
            rest = line[close + 1:]
            before = line[:start]
            if re.search(r"(^|[^\w)\]\s])\s*-\s*$|^\s*-\s*$", before if text_form else line[:max(receiver_start(line, start), 0)]):
                self.note(i, "`-` of a `compare` result: write `b.order(?a)`, or compare `a.order(?b)` with the `Order` it means")
                continue
            r = re.match(r"\s*(<=|>=|==|!=|<|>)\s*0\b(?!\.)", rest)
            lb = re.search(r"\b0\s*(<=|>=|==|!=|<|>)\s*$", before) if text_form else None
            if r:
                eq, v = CMP[r.group(1)]
                self.lines[i] = before + call + " %s .%s" % (eq, v) + rest[r.end():]
                self.n += 1
                at = 0
                continue
            if lb:
                eq, v = CMP[FLIP[lb.group(1)]]
                self.lines[i] = before[:lb.start()] + call + " %s .%s" % (eq, v) + rest
                self.n += 1
                at = 0
                continue
            a = re.match(r"^\s*(\w+)\s*=\s*", before)
            recv = before[a.end():] if a else None
            whole = a and rest.strip() == "" and (recv == "" if text_form else recv and receiver_start(before, len(before)) == a.end())
            if whole and self.bound(i, a.group(1), head):
                at = 0
                continue
            self.note(i, "a `compare` result used as an `Int`: compare `a.order(?b)` with `.less`, `.equal`, or `.greater`")

    def function_of(self, i):
        """The lines of the function line `i` is in: from its `fun` or
        `sub` line to the line before the next line as shallow."""
        ind = len(self.lines[i]) - len(self.lines[i].lstrip())
        s = i
        while s > 0:
            s -= 1
            t = self.lines[s]
            if t.strip() and re.match(r"^\s*(pub\s+)?(fun|sub)\s", t) and len(t) - len(t.lstrip()) < ind:
                break
        else:
            return 0, len(self.lines)
        d = len(self.lines[s]) - len(self.lines[s].lstrip())
        e = s + 1
        while e < len(self.lines):
            t = self.lines[e]
            if t.strip() and not t.strip().startswith("#") and len(t) - len(t.lstrip()) <= d:
                break
            e += 1
        return s, e

    def bound(self, i, name, head):
        """Rewrite `name = <compare>` at line `i` with every use of `name`
        in its function, when each use compares it with 0 and each
        assignment to it is a compare; false, rewriting nothing, else."""
        s, e = self.function_of(i)
        use = re.compile(r"\b%s\b" % re.escape(name))
        sites = []
        for k in range(s, e):
            line = self.lines[k]
            mask = code_mask(line)
            for m in use.finditer(line):
                if not mask[m.start()]:
                    continue
                after = line[m.end():]
                before = line[:m.start()]
                if re.match(r"\s*=[^=]", after):
                    if not re.search(head, after) or not re.match(r"^\s*$", before):
                        return False
                    continue
                if before.rstrip().endswith(".") or re.match(r"\s*:", after):
                    return False
                r = re.match(r"\s*(<=|>=|==|!=|<|>)\s*0\b(?!\.)", after)
                lb = re.search(r"\b0\s*(<=|>=|==|!=|<|>)\s*$", before)
                if r:
                    sites.append((k, m.start(), m.end() + r.end(), CMP[r.group(1)]))
                elif lb:
                    sites.append((k, lb.start(), m.end(), CMP[FLIP[lb.group(1)]]))
                else:
                    return False
        for k, a, b, (eq, v) in sorted(sites, reverse=True):
            line = self.lines[k]
            self.lines[k] = line[:a] + "%s %s .%s" % (name, eq, v) + line[b:]
            self.n += 1
        # Each assignment's call, as an Order.
        for k in range(s, e):
            line = self.lines[k]
            m = re.match(r"^(\s*)%s\s*=\s*" % re.escape(name), line)
            if not m:
                continue
            h = re.search(head, line[m.end():])
            if not h:
                continue
            at = m.end() + h.start()
            open_at = m.end() + h.end() - 1
            close = closing(line, open_at)
            inner = line[open_at + 1:close]
            if head.endswith(r"\.compare\(") and not head.startswith(r"\."):
                args = split_args(inner)
                call = "%s.order(%s)" % (as_receiver(args[0]), as_view(args[1]))
                self.lines[k] = line[:at] + call + line[close + 1:]
            else:
                self.lines[k] = line[:at] + ".order(%s)" % inner + line[close + 1:]
            self.n += 1
        return True

    def bigint(self):
        if not self.declares("compare"):
            self.compares(r"\.compare\(", text_form=False)
        if not self.declares("to_f64"):
            for i in range(len(self.lines)):
                self.sub(r"\.to_f64\(\)", ".to_float()", i)
        if self.declares("equals"):
            return
        for i in range(len(self.lines)):
            while True:
                line = self.lines[i]
                mask = code_mask(line)
                m = next((mm for mm in re.finditer(r"\.equals\(", line) if mask[mm.start()]), None)
                if not m:
                    break
                close = closing(line, m.end() - 1)
                start = receiver_start(line, m.start())
                if close < 0 or start < 0:
                    self.note(i, "`equals` of a BigInt: write `a == b`")
                    break
                recv = line[start:m.start()]
                other = line[m.end():close].strip()
                if other.startswith("?"):
                    other = other[1:]
                op = "=="
                a = start
                n = re.search(r"\bnot\s+$", line[:start])
                if n:
                    op, a = "!=", n.start()
                expr = "%s %s %s" % (recv, op, other)
                if line[close + 1:close + 2] == "." or re.match(r"\s*(==|!=|<=|>=|<|>|\?\?)", line[close + 1:]):
                    expr = "(%s)" % expr
                self.lines[i] = line[:a] + expr + line[close + 1:]
                self.n += 1

    def iter(self):
        for it in self.mods("iter"):
            for i in range(len(self.lines)):
                at = 0
                while True:
                    line = self.lines[i]
                    mask = code_mask(line)
                    m = next((mm for mm in re.finditer(r"\b%s\.(count|sum)\(" % re.escape(it), line) if mm.start() >= at and mask[mm.start()]), None)
                    if not m:
                        break
                    at = m.end()
                    close = closing(line, m.end() - 1)
                    arg = line[m.end():close].strip() if close > 0 else ""
                    if not arg.startswith("!"):
                        self.note(i, "`%s.%s` of other than a write lend `!it`" % (it, m.group(1)))
                        continue
                    rest = line[close + 1:]
                    if m.group(1) == "sum":
                        z = re.match(r"\s*\?\?\s*0(\.0+)?(?=\s*($|#|[),\]]|\s(and|or|if|else)\b))", rest)
                        if not z:
                            if re.match(r"\s*\?\?", rest):
                                self.note(i, "`iter.sum(!it) ?? ...` with more after it, which `??` takes in (`?? 0 + 1` is `?? (0 + 1)`): write `(!it).sum()` and what the default means")
                            else:
                                self.note(i, "`iter.sum` gives `none` for no items, and a chain's `sum()` 0: write `(!it).sum()` where 0 serves")
                            continue
                        rest = rest[z.end():]
                    self.lines[i] = line[:m.start()] + "(%s).%s()" % (arg, m.group(1)) + rest
                    self.n += 1
        # `use std.iter` goes once no code names the module.
        left = False
        for ln in self.lines:
            mask = code_mask(ln)
            if USE.match(ln):
                continue
            for it in self.mods("iter"):
                for m in re.finditer(r"\b%s\." % re.escape(it), ln):
                    if mask[m.start()]:
                        left = True
        if left:
            return
        keep, origin = [], []
        drop_blank = False
        for ln, o in zip(self.lines, self.origin):
            m = USE.match(ln)
            if m and m.group(1) == "iter":
                self.n += 1
                # A blank line after it goes too when nothing precedes it
                # but a blank line or the start.
                drop_blank = not keep or not keep[-1].strip()
                continue
            if drop_blank and not ln.strip():
                drop_blank = False
                continue
            drop_blank = False
            keep.append(ln)
            origin.append(o)
        self.lines[:] = keep
        self.origin[:] = origin

    def needles(self):
        heads = [(s, ("contains", "index_of")) for s in self.mods("slices")] + [(s, ("lower_bound", "search")) for s in self.mods("sort")]
        for s, fns in heads:
            for i in range(len(self.lines)):
                line = self.lines[i]
                mask = code_mask(line)
                for m in list(re.finditer(r"\b%s\.(%s)\(" % (re.escape(s), "|".join(fns)), line))[::-1]:
                    if not mask[m.start()]:
                        continue
                    close = closing(line, m.end() - 1)
                    if close < 0:
                        continue
                    args = split_args(line[m.end():close])
                    if len(args) == 2 and args[1][:1] in "<+" and is_path(args[1][1:]):
                        line = line[:m.end()] + args[0] + ", ?" + args[1][1:] + line[close:]
                        self.n += 1
                    elif len(args) == 2 and re.search(r"\sif\s.*\selse\s", flat(args[1])):
                        line = line[:m.end()] + args[0] + ", ?(" + args[1] + ")" + line[close:]
                        self.n += 1
                self.lines[i] = line


def migrate_lines(path, first, lines):
    u = Unit(path, first, list(lines))
    u.run()
    return u.lines, u.n, u.manual


def migrate_markdown(path, text):
    out, n, manual = [], 0, []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        info = lines[i].strip()[3:].strip() if m else ""
        if m and info.split()[:1] == ["rig"]:
            j = i + 1
            while j < len(lines) and not FENCE.match(lines[j]):
                j += 1
            body = lines[i + 1:j]
            new, k, man = migrate_lines(path, i + 1, body)
            if "reject" in info.split() and new != body:
                manual.append("MANUAL %s:%d: a ```rig reject block naming an old name, maybe on purpose" % (path, i + 1))
                new, k, man = body, 0, []
            out.append(lines[i])
            out.extend(new)
            n += k
            manual.extend(man)
            i = j
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out), n, manual


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in sorted(dirs) if not d.startswith(".") and d not in ("zig-cache", ".zig-cache", "node_modules", "zig-out")]
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.tmpl", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv if a != "--dry-run"]
    if not paths:
        print(__doc__.strip().splitlines()[-5], file=sys.stderr)
        return 2
    total, manual = 0, []
    for path in files(paths):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if path.endswith(".md"):
            new, n, man = migrate_markdown(path, text)
        else:
            lines, n, man = migrate_lines(path, 0, text.split("\n"))
            new = "\n".join(lines)
        manual.extend(man)
        if n == 0:
            continue
        total += n
        print("%s: %d" % (path, n))
        if not dry:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
    for m in manual:
        print(m)
    print("%d rewritten, %d MANUAL" % (total, len(manual)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
