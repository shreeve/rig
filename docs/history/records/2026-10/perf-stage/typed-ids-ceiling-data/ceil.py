#!/usr/bin/env python3
"""ceil.py SRC DST MODE [--list FILE]: copy Rig's emitted Trig package SRC
to DST and remove the bounds test of each lookup item 1 (typed table ids)
would make provably in range. MODE:

  base    unchanged (the copy only)
  hot     the hot id sites: the lookups by an id read from memory that
          codegen-gap's sample named (Ids' sym_loc, tab_loc, node_base,
          sym_base and tab_base; the checker's syms by checker_symbol;
          the binder's bindings and symbols by a symbol's file and local
          index; the program's files by a node's file; symbol_data; the
          AST's recs by n.id; the Interner's ends by an atom)
  ids     every lookup whose index is a table id read from memory (the
          classifier below), hot sites included
  idspan  ids, and every span read: a lookup at a start read from memory
          plus an offset (`type_lists.atInt(list.start + k)`,
          `words.at(recs.at(n.id).data + off)`)

An unchecked lookup is the List's (or slice's, or Table's) element read
through its pointer with no compare, as a slot is (`atU`, `slotU`,
`constSlotU`, `atIntU`, ...); no fact is given to LLVM (no `unreachable`).
A half-proven lookup (`atProven(i, .lower)`) is made `.both`.

The classifier, by the index's text, wrappers stripped (`rig.rt(..)`,
`@as(i64, @intCast(@as(u32, ..)))`, `@intCast(..)`):
  id     a field read (`n.id`, `x.file`), a call's result
         (`self.checker_symbol(s)`, `self.ids.local_sym(s)`), a U32
         widened to Int, a parameter, a `for`/`while` capture of an
         element, or a `const` local bound to one of these; or one of
         these less 1 (`file - 1`)
  span   one of the above plus a local or a literal (`list.start + k`)
  other  a `var` local (a loop counter), an index capture, arithmetic on
         locals (`i + 1`, `lo + hi`), a length, a literal
"""
import os, re, shutil, sys, json, collections

METHODS = {"at": "atU", "slot": "slotU", "constSlot": "constSlotU",
           "atInt": "atIntU", "slotInt": "slotIntU", "constSlotInt": "constSlotIntU"}
PROVEN = {"atProven", "slotProven", "constSlotProven"}
FREE = {"at": "atU", "elemPtr": "elemPtrU"}
FREE_PROVEN = {"atProven", "elemPtrProven"}
CALL_RE = re.compile(r"(rig\.)?\b(at|slot|constSlot|atInt|slotInt|constSlotInt|atProven|slotProven|constSlotProven|elemPtr|elemPtrProven)\(")
FN_RE = re.compile(r"^(\s*)(pub )?(inline |noinline |export )?fn ([A-Za-z_][A-Za-z0-9_]*)\((.*)$")

# The hot sites: codegen-gap's sampled id lines, by their receiver.
HOT = [
    r"\bself\.(sym_loc|tab_loc|node_base|sym_base|tab_base)\.at\(",
    r"\bself\.syms\.atInt\(rig\.rt\(self\.checker_symbol\(",
    r"\bbindings\.constSlot\(",
    r"\.symbols\.constSlot\(",
    r"\bfiles\.constSlot\(",
    r"\bsymbol_data\.(constSlot|slot|at)\(",
    r"\bself\.recs\.(at|slot)\(n\.id\)",
    r"\bself\.ends\.atProven\(i, \.lower\)",
]
HOT_RE = [re.compile(h) for h in HOT]


def balanced(s, i):
    """s[i] is just past '('; return the index of the matching ')'."""
    d = 1
    while i < len(s):
        c = s[i]
        if c in "([{": d += 1
        elif c in ")]}":
            d -= 1
            if d == 0: return i
        elif c == '"':
            i += 1
            while i < len(s) and s[i] != '"':
                if s[i] == "\\": i += 1
                i += 1
        i += 1
    return -1


def split_args(a):
    out, d, cur = [], 0, ""
    for c in a:
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        if c == "," and d == 0: out.append(cur.strip()); cur = ""
        else: cur += c
    out.append(cur.strip())
    return out


def strip(e):
    e = e.strip()
    while True:
        for pre in ("rig.rt(", "@intCast(", "@as(i64, ", "@as(u32, ", "@as(usize, ", "@as(i32, ", "@as(u64, "):
            if e.startswith(pre) and e.endswith(")") and balanced(e, len(pre)) == len(e) - 1:
                e = e[len(pre):-1].strip(); break
        else:
            if e.startswith("(") and balanced(e, 1) == len(e) - 1:
                e = e[1:-1].strip(); continue
            return e


def top_binop(e):
    """The last top-level ` + ` or ` - ` of e, as (left, op, right), or None."""
    d = 0; last = None
    for i, c in enumerate(e):
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        elif d == 0 and c in "+-" and i > 0 and e[i - 1] == " " and i + 1 < len(e) and e[i + 1] == " ":
            last = i
    if last is None: return None
    return e[:last - 1].strip(), e[last], e[last + 2:].strip()


IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FIELD = re.compile(r'^(@"\w+"|[A-Za-z_])[\w.*@"]*\.[A-Za-z_]\w*$')      # a.b, self.x.y, p.*.f
CALLX = re.compile(r"^[A-Za-z_][\w.*]*\(.*\)(\.[A-Za-z_]\w*)*$", re.S)


class Scope:
    """The enclosing function of a line: its parameters and the bindings
    made before the line."""
    def __init__(self, lines, fn_starts):
        self.lines = lines
        self.ranges = []
        for s in fn_starts:
            ind = FN_RE.match(lines[s]).group(1); e = s + 1
            if lines[s].rstrip().endswith("{"):
                while e < len(lines) and lines[e] != ind + "}": e += 1
            self.ranges.append((s, e))

    def fn_of(self, k):
        best = 0
        for s, e in self.ranges:
            if s > k: break
            if s <= k <= e: best = s
        return best

    def binding(self, name, k):
        """How `name` is bound before line k in its function: ('param', type),
        ('const', init), ('var', init), ('cap', 'elem'|'index'), or None."""
        s = self.fn_of(k)
        hdr = self.lines[s]
        m = FN_RE.match(hdr)
        best = None
        if m:
            params = m.group(5)
            for p in re.finditer(r"(?:__rig_in_)?(\w+): ([^,)]+)", params):
                if p.group(1) == name: best = ("param", p.group(2).strip())
        for j in range(s + 1, k + 1):
            l = self.lines[j]
            mm = re.search(r"\b(const|var) " + re.escape(name) + r"(?:: ([^=]+))? = ", l)
            if mm:
                init = l[mm.end():]; d = 0
                for q, c in enumerate(init):
                    if c in "([{": d += 1
                    elif c in ")]}": d -= 1
                    elif c == ";" and d == 0: init = init[:q]; break
                if mm.group(1) == "var":
                    ty = (mm.group(2) or "").strip()
                    best = ("var", ty); continue
                if mm.group(1) == "const" and init.startswith("rig.rt(__rig_in_"):
                    continue  # an inline function's parameter, typed in the header
                best = (mm.group(1), init); continue
            mm = re.search(r"\|([^|]*)\|", l)
            if mm and re.match(r"\s*(for|while|if)\b|.*\) \|", l):
                caps = [c.strip().lstrip("*") for c in mm.group(1).split(",")]
                if name in caps:
                    is_for = re.search(r"\bfor \(", l) is not None
                    idx = is_for and len(caps) > 1 and caps.index(name) == len(caps) - 1
                    best = ("cap", "index" if idx else "elem")
        return best


def classify(arg, scope, k, depth=0):
    e = strip(arg)
    u32 = "@as(u32, " in arg
    if depth > 4: return "other"
    if re.fullmatch(r"-?\d+", e): return "other"
    if e.startswith("rig.lenOf(") or e.startswith("rig.rem(") or e.startswith("@divTrunc("): return "other"
    b = top_binop(e)
    if b:
        l, op, r = b
        cl = classify(l, scope, k, depth + 1)
        if op == "-" and strip(r) == "1" and cl == "id": return "id"
        if op == "+" and cl == "id":
            rr = strip(r)
            if IDENT.match(rr) or re.fullmatch(r"\d+", rr): return "span"
        if op == "+" and cl in ("id", "span") and classify(r, scope, k, depth + 1) == "id":
            return "other"
        return "other"
    mt = re.fullmatch(r"([A-Za-z_]\w*)\[\d+\]", e)
    if mt: return classify(mt.group(1), scope, k, depth + 1)
    if FIELD.match(e):
        last = e.rsplit(".", 1)[1]
        if last in ("len",): return "other"
        return "id"
    if CALLX.match(e):
        return "id"
    if IDENT.match(e):
        bnd = scope.binding(e, k)
        if bnd is None: return "id" if u32 else "other"
        kind, info = bnd
        if kind == "param":
            # an Int parameter is an index as often as an id; an id type is an id
            return "id" if (info != "i64" or u32) else "param-int"
        if kind == "cap": return "id" if info == "elem" else "other"
        if kind == "const": return classify(info, scope, k, depth + 1)
        # var: an Int is a counter; a U32 or an id type holds an id
        return "id" if info not in ("", "i64", "usize", "u64", "i32") else "other"
    return "other"


def hot(line, at):
    """Whether a HOT pattern in `line` covers the call's name at `at`."""
    return any(m.start() <= at < m.end() for h in HOT_RE for m in h.finditer(line))


RT_TWINS_LIST = """
        // CEIL (typed-ids-ceiling): the element at `i` with no test, as a slot reads.
        pub inline fn atU(self: *const Self, i: anytype) T {
            return self.memConst().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
        pub inline fn slotU(self: *Self, i: anytype) *T {
            return &self.mem().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
        pub inline fn constSlotU(self: *const Self, i: anytype) *const T {
            return &self.memConst().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
"""
RT_TWINS_FREE = """

// CEIL (typed-ids-ceiling): `s[i]` with no test.
pub inline fn atU(items: anytype, i: anytype) std.meta.Elem(@TypeOf(items)) {
    return items.ptr[@as(usize, @bitCast(@as(i64, i)))];
}
pub inline fn elemPtrU(items: anytype, i: anytype) @TypeOf(&items[0]) {
    return &items.ptr[@as(usize, @bitCast(@as(i64, i)))];
}
pub inline fn sliceU(items: anytype, lo: anytype, hi: anytype) []const std.meta.Elem(@TypeOf(items)) {
    return items.ptr[@as(usize, @bitCast(@as(i64, lo)))..@as(usize, @bitCast(@as(i64, hi)))];
}
"""
TABLE_TWINS = """        // CEIL (typed-ids-ceiling): an integer index taken as a slot, with no test.
        pub const atU = at;
        pub const slotU = slot;
        pub const constSlotU = constSlot;
        inline fn indexU(i: anytype) Index {
            return @truncate(@as(u64, @bitCast(@as(i64, i))));
        }
        pub inline fn atIntU(self: *const Self, i: anytype) T {
            return self.at(indexU(i));
        }
        pub inline fn constSlotIntU(self: *const Self, i: anytype) *const T {
            return self.constSlot(indexU(i));
        }
        pub inline fn slotIntU(self: *Self, i: anytype) *T {
            return self.slot(indexU(i));
        }

"""


def sub1(t, old, new):
    assert t.count(old) == 1, old
    return t.replace(old, new)


def patch_rt(dst):
    p = os.path.join(dst, "rig/runtime.zig"); t = open(p).read()
    anchor = "        /// `at`, `slot`, and `constSlot` with the tests `p` proves omitted"
    t = sub1(t, anchor, RT_TWINS_LIST.lstrip("\n") + "\n" + anchor)
    t += RT_TWINS_FREE
    open(p, "w").write(t)
    p = os.path.join(dst, "rig/table.zig"); t = open(p).read()
    anchor = "        /// What a committed table's slot past `cap` reads as."
    t = sub1(t, anchor, TABLE_TWINS + anchor)
    open(p, "w").write(t)


def alias_user(path):
    """A user type's own at/slot/constSlot gets a `U` alias, so a renamed
    call reaches it unchanged."""
    lines = open(path).read().split("\n"); out = []; i = 0; n = 0
    while i < len(lines):
        out.append(lines[i]); m = FN_RE.match(lines[i])
        if m and m.group(4) in METHODS and lines[i].rstrip().endswith("{"):
            ind = m.group(1); j = i + 1
            while j < len(lines) and lines[j] != ind + "}":
                out.append(lines[j]); j += 1
            out.append(lines[j]); out.append(f"{ind}pub const {METHODS[m.group(4)]} = {m.group(4)};"); n += 1
            i = j + 1; continue
        i += 1
    if n: open(path, "w").write("\n".join(out))


def edit_file(path, mode, sites):
    t = open(path).read(); lines = t.split("\n")
    fn_starts = [i for i, l in enumerate(lines) if FN_RE.match(l)]
    sc = Scope(lines, fn_starts)
    rel = os.path.basename(path)
    for k, line in enumerate(lines):
        if "(" not in line: continue
        out = []; pos = 0; changed = False
        for m in CALL_RE.finditer(line):
            if m.start() < pos: continue
            free = m.group(1) is not None
            name = m.group(2)
            if not free and (m.start() == 0 or line[m.start() - 1] != "."): continue
            if free and name not in FREE and name not in FREE_PROVEN: continue
            if not free and name not in METHODS and name not in PROVEN: continue
            a0 = m.end(); a1 = balanced(line, a0)
            if a1 < 0: continue
            args = split_args(line[a0:a1])
            idx = args[1] if free else args[0]
            if (free or name in PROVEN) and name.endswith("Proven"):
                if len(args) < (3 if free else 2) or args[-1] not in (".lower", ".upper"): continue
            cls = classify(idx, sc, k)
            if cls == "span" and rel not in ("ast.zig", "checker.zig"):
                cls = "other"  # a text position plus an offset (lexer, parser, printer), not a table's span
            is_hot = hot(line, m.start(2)) and cls != "other"
            sites.append((rel, k + 1, name, cls, is_hot, idx.strip()[:90]))
            take = (mode == "hot" and is_hot) or (mode in ("ids", "idspan") and (cls == "id" or is_hot)) or (mode == "idspan" and cls == "span")
            if not take: continue
            if name.endswith("Proven"):
                seg = line[m.start():a1 + 1]
                seg = re.sub(r", \.(lower|upper)\)$", ", .both)", seg)
                out.append(line[pos:m.start()]); out.append(seg); pos = a1 + 1; changed = True
            else:
                new = (FREE if free else METHODS)[name]
                out.append(line[pos:m.start()]); out.append(("rig." if free else "") + new + "(")
                pos = m.end(); changed = True
        if changed:
            out.append(line[pos:]); lines[k] = "".join(out)
    if mode == "idspan" and rel == "__rig_std_text.zig":
        # the Interner's text: its bytes from start to end, both read from ends by the atom
        old = "        return rig.slice(self.bytes.bytes(), start, end);"
        assert lines.count(old) == 1
        lines[lines.index(old)] = "        return rig.sliceU(self.bytes.bytes(), start, end);"
        sites.append((rel, lines.index("        return rig.sliceU(self.bytes.bytes(), start, end);") + 1, "slice", "span", True, "start, end"))
    open(path, "w").write("\n".join(lines))


def main():
    src, dst, mode = sys.argv[1:4]
    listf = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--list" else None
    if os.path.exists(dst): shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".git", ".zig-cache"))
    if mode == "base": return
    patch_rt(dst)
    sites = []
    for f in sorted(os.listdir(dst)):
        if f.endswith(".zig"):
            alias_user(os.path.join(dst, f))
            edit_file(os.path.join(dst, f), mode, sites)
    c = collections.Counter((s[3], s[4]) for s in sites)
    taken = sum(1 for s in sites if (mode == "hot" and s[4]) or (mode in ("ids", "idspan") and (s[3] == "id" or s[4])) or (mode == "idspan" and s[3] == "span"))
    print(json.dumps({"mode": mode, "sites": len(sites), "taken": taken,
                      "by class (hot)": {f"{k[0]}{' hot' if k[1] else ''}": v for k, v in sorted(c.items())}}))
    if listf:
        with open(listf, "w") as f:
            for s in sites: f.write("%s:%d\t%s\t%s%s\t%s\n" % (s[0], s[1], s[2], s[3], " hot" if s[4] else "", s[5]))


if __name__ == "__main__":
    main()
