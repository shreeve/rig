#!/usr/bin/env python3
"""ceil.py SRC DST [--off K,K...] [--group G,G... --rig] [--group-zig G,G...]

Copy Trig's emitted package SRC to DST with the check-bisect scaffolding:
every check of Rig's runtime and every one of Zig's own safety tests is
gated by a kind, and a kind named in --off makes its failure unreachable
(LLVM then assumes the test passes and drops it). With every kind on, the
scaffolding emits what main emits: each gate is an inline function that
folds to the original panic call.

Rig's kinds (rig/runtime.zig, rig/table.zig):
  li     an index test on a List, a slice, a string, or an array
  ti     a Table's index test by an integer (t[i], Slot[n] tests)
  sl     slice bounds (s[lo..hi], ..=)
  len    a length's test against max_len
  bytes  a byte read or write's range test
  keep   push(keep: k)'s test
  full   a Table's full test on push
Zig's own safety tests (the root's panic namespace):
  ov     integer overflow (+, -, *, @shlExact, ...)
  cast   @intCast and float-to-int range tests
  unwrap optional and error unwrap (.?, catch unreachable)
  enumv  enum conversion, corrupt switch, inactive union field
  unreach reached unreachable
  zbounds Zig's own index and slice tests
  zother everything else of Zig's (division, shifts, alignment, ...)

Groups (--group, with --rig): the List index and slice tests made in a
group's functions get kinds gli and gsl (and a Table's integer index
gti), named in --off to remove them in that group alone. --group-zig
puts @setRuntimeSafety(false) at the top of every function of the groups,
removing all of Zig's safety tests there.
"""
import os, re, shutil, sys, argparse, json

ZIG_KINDS = {
    "call": None,
    "sentinelMismatch": "zother", "unwrapError": "unwrap", "outOfBounds": "zbounds",
    "startGreaterThanEnd": "zbounds", "inactiveUnionField": "enumv",
    "sliceCastLenRemainder": "zother", "reachedUnreachable": "unreach",
    "unwrapNull": "unwrap", "castToNull": "zother", "incorrectAlignment": "zother",
    "invalidErrorCode": "zother", "unexpectedErrorCode": "zother",
    "integerOutOfBounds": "cast", "integerOverflow": "ov", "shlOverflow": "ov",
    "shrOverflow": "zother", "divideByZero": "zother", "exactDivisionRemainder": "zother",
    "integerPartOutOfBounds": "cast", "corruptSwitch": "enumv", "shiftRhsTooBig": "zother",
    "invalidEnumValue": "enumv", "forLenMismatch": "zother", "copyLenMismatch": "zother",
    "memcpyAlias": "zother", "noreturnReturned": "zother", "loadUninstantiableType": "zother",
}
ZIG_SIG = {
    "sentinelMismatch": "(_: anytype, _: anytype)", "unwrapError": "(_: anyerror)",
    "outOfBounds": "(_: usize, _: usize)", "startGreaterThanEnd": "(_: usize, _: usize)",
    "inactiveUnionField": "(_: anytype, _: anytype)", "sliceCastLenRemainder": "(_: usize)",
    "unexpectedErrorCode": "(_: anyerror)",
}
RIG_KINDS = ["li", "ti", "sl", "len", "bytes", "keep", "full", "gli", "gsl", "gti"]
ALL_ZIG = sorted(set(v for v in ZIG_KINDS.values() if v))
ALL = RIG_KINDS + ALL_ZIG


def sub1(text, old, new, count=1):
    n = text.count(old)
    if n != count:
        raise SystemExit(f"expected {count} of {old!r}, found {n}")
    return text.replace(old, new)


def patch_runtime(t):
    # Rig's panics, by kind. The definitions keep their names.
    t = t.replace("indexPanic();", 'indexPanicK("li");').replace("orelse indexPanic()]", 'orelse indexPanicK("li")]')
    t = sub1(t, 'fn indexPanicK("li"); noreturn', "fn indexPanic() noreturn", 0) if 'fn indexPanicK("li")' in t else t
    t = t.replace("slicePanic();", 'slicePanicK("sl");')
    t = t.replace("lenPanic();", 'lenPanicK("len");')
    t = t.replace("orelse bytesPanic(", 'orelse bytesPanicK("bytes", ')
    t = t.replace("keepPanic(count, n);", 'keepPanicK(count, n);')
    t = sub1(t, "    noinline fn keepPanic(count: Int, n: usize) noreturn {",
             '    inline fn keepPanicK(count: Int, n: usize) noreturn {\n        gate("keep");\n        keepPanic(count, n);\n    }\n\n    noinline fn keepPanic(count: Int, n: usize) noreturn {')
    # The index test, as a function of its kind.
    old_index = """pub fn index(i: anytype, count: usize) usize {
    const idx = std.math.cast(usize, i) orelse indexPanicK("li");
    if (idx >= count) indexPanicK("li");
    return idx;
}"""
    t = sub1(t, old_index, old_index + """

/// CEIL: `index`, its test of kind `k`.
pub fn indexK(comptime k: []const u8, i: anytype, count: usize) usize {
    const idx = std.math.cast(usize, i) orelse indexPanicK(k);
    if (idx >= count) indexPanicK(k);
    return idx;
}""")
    old_below = """pub inline fn indexBelow(i: anytype, comptime n: u64) usize {
    if (comptime n > std.math.maxInt(usize)) @compileError("rig.indexBelow: a count past the address space");
    const info = @typeInfo(@TypeOf(i));
    if (comptime info == .int and info.int.signedness == .signed and info.int.bits <= 64 and n <= 1 << 63) {
        // One compare, as `offsetBelow` makes it.
        const u: u64 = @bitCast(@as(i64, i));
        if (u >= n) indexPanicK("li");
        // Exact: below `n`, which a `usize` holds.
        return @truncate(u);
    }
    // An unsigned `i` has no sign to test: `index`'s one compare.
    return index(i, n);
}"""
    new_below = old_below.replace("pub inline fn indexBelow(i", "pub inline fn indexBelowK(comptime k: []const u8, i").replace(
        'indexPanicK("li")', "indexPanicK(k)").replace("return index(i, n);", "return indexK(k, i, n);")
    t = sub1(t, old_below, old_below + "\n\n/// CEIL: `indexBelow`, its test of kind `k`.\n" + new_below)
    old_bounds = """fn bounds(count: usize, lo: anytype, hi: anytype) [2]usize {
    const l = std.math.cast(usize, lo) orelse slicePanicK("sl");
    const h = if (@TypeOf(hi) == @TypeOf(null)) count else std.math.cast(usize, hi) orelse slicePanicK("sl");
    if (l > h or h > count) slicePanicK("sl");
    return .{ l, h };
}"""
    t = sub1(t, old_bounds, old_bounds + "\n\n" + old_bounds.replace("fn bounds(", "fn boundsK(comptime k: []const u8, ").replace('slicePanicK("sl")', "slicePanicK(k)"))
    # List twins, after constSlotIf.
    old_list = """        inline fn provenSlot(self: *const Self, idx: ?usize) usize {
            const slot_ = idx orelse indexPanicK("li");
            invariant(slot_ < self.memConst().len);
            return slot_;
        }"""
    twins = """
        // CEIL: the group twins of at, slot, constSlot and the proven forms.
        pub fn at__g(self: *const Self, i: anytype) T {
            return self.memConst().ptr[self.indexOf__g(i)];
        }
        pub fn slot__g(self: *Self, i: anytype) *T {
            return &self.mem().ptr[self.indexOf__g(i)];
        }
        pub fn constSlot__g(self: *const Self, i: anytype) *const T {
            return &self.memConst().ptr[self.indexOf__g(i)];
        }
        inline fn indexOf__g(self: *const Self, i: anytype) usize {
            const idx = indexK("gli", i, self.len);
            invariant(idx < self.memConst().len);
            return idx;
        }
        pub inline fn atProven__g(self: *const Self, i: Int, comptime p: Proven) T {
            return self.memConst().ptr[self.provenSlot__g(provenOffset(i, self.len, 1, p))];
        }
        pub inline fn slotProven__g(self: *Self, i: Int, comptime p: Proven) *T {
            return &self.mem().ptr[self.provenSlot__g(provenOffset(i, self.len, 1, p))];
        }
        pub inline fn constSlotProven__g(self: *const Self, i: Int, comptime p: Proven) *const T {
            return &self.memConst().ptr[self.provenSlot__g(provenOffset(i, self.len, 1, p))];
        }
        pub inline fn atIf__g(self: *const Self, i: Int, comptime p: ?Proven, comptime q: Proven, ok: bool) T {
            return self.memConst().ptr[self.provenSlot__g(offsetIf(i, self.len, 1, p, q, ok))];
        }
        pub inline fn slotIf__g(self: *Self, i: Int, comptime p: ?Proven, comptime q: Proven, ok: bool) *T {
            return &self.mem().ptr[self.provenSlot__g(offsetIf(i, self.len, 1, p, q, ok))];
        }
        pub inline fn constSlotIf__g(self: *const Self, i: Int, comptime p: ?Proven, comptime q: Proven, ok: bool) *const T {
            return &self.memConst().ptr[self.provenSlot__g(offsetIf(i, self.len, 1, p, q, ok))];
        }
        inline fn provenSlot__g(self: *const Self, idx: ?usize) usize {
            const slot_ = idx orelse indexPanicK("gli");
            invariant(slot_ < self.memConst().len);
            return slot_;
        }"""
    t = sub1(t, old_list, old_list + "\n" + twins)
    t = sub1(t, "pub const panic = std.debug.FullPanic(panicAfterFlush);",
             "pub const panic = CeilPanic(std.debug.FullPanic(panicAfterFlush));")
    # Free twins and the gates.
    zig_ns = ["fn CeilPanic(comptime P: type) type {", "    return struct {"]
    for name, kind in ZIG_KINDS.items():
        if kind is None:
            zig_ns.append(f"        pub const {name} = P.{name};")
        else:
            zig_ns.append(f'        pub const {name} = if (ceil.{kind}) CeilU.{name} else P.{name};')
    zig_ns.append("    };\n}")
    u = ["const CeilU = struct {"]
    for name, kind in ZIG_KINDS.items():
        if kind is None: continue
        u.append(f"    fn {name}{ZIG_SIG.get(name, '()')} noreturn {{\n        @setRuntimeSafety(false);\n        unreachable;\n    }}")
    u.append("};")
    t += """

// -----------------------------------------------------------------------------
// CEIL: check-bisect scaffolding (measurement only, never landed)
// -----------------------------------------------------------------------------

const ceil = @import("ceil.zig");

/// A check of kind `k` that fails: unreachable when `k` is off, else
/// nothing (the caller then panics as it always does).
pub inline fn gate(comptime k: []const u8) void {
    if (comptime @field(ceil, k)) {
        @setRuntimeSafety(false);
        unreachable;
    }
}
inline fn indexPanicK(comptime k: []const u8) noreturn {
    gate(k);
    indexPanic();
}
inline fn slicePanicK(comptime k: []const u8) noreturn {
    gate(k);
    slicePanic();
}
inline fn lenPanicK(comptime k: []const u8) noreturn {
    gate(k);
    lenPanic();
}
inline fn bytesPanicK(comptime k: []const u8, comptime what: []const u8, n: usize, offset: anytype, count: usize) noreturn {
    gate(k);
    bytesPanic(what, n, offset, count);
}

pub fn at__g(items: anytype, i: anytype) std.meta.Elem(@TypeOf(items)) {
    return items[indexK("gli", i, items.len)];
}
pub fn elemPtr__g(items: anytype, i: anytype) @TypeOf(&items[0]) {
    return &items[indexK("gli", i, items.len)];
}
pub inline fn atProven__g(items: anytype, i: Int, comptime p: Proven) std.meta.Elem(@TypeOf(items)) {
    return items.ptr[provenOffset(i, items.len, 1, p) orelse indexPanicK("gli")];
}
pub inline fn elemPtrProven__g(items: anytype, i: Int, comptime p: Proven) @TypeOf(&items[0]) {
    return &items.ptr[provenOffset(i, items.len, 1, p) orelse indexPanicK("gli")];
}
pub inline fn atIf__g(items: anytype, i: Int, comptime p: ?Proven, comptime q: Proven, ok: bool) std.meta.Elem(@TypeOf(items)) {
    return items.ptr[offsetIf(i, items.len, 1, p, q, ok) orelse indexPanicK("gli")];
}
pub inline fn elemPtrIf__g(items: anytype, i: Int, comptime p: ?Proven, comptime q: Proven, ok: bool) @TypeOf(&items[0]) {
    return &items.ptr[offsetIf(i, items.len, 1, p, q, ok) orelse indexPanicK("gli")];
}
pub inline fn indexBelow__g(i: anytype, comptime n: u64) usize {
    return indexBelowK("gli", i, n);
}
pub fn slice__g(items: anytype, lo: anytype, hi: anytype) []const std.meta.Elem(@TypeOf(items)) {
    const b = boundsK("gsl", items.len, lo, hi);
    return items[b[0]..b[1]];
}
pub fn sliceMut__g(items: anytype, lo: anytype, hi: anytype) []std.meta.Elem(@TypeOf(items)) {
    const b = boundsK("gsl", items.len, lo, hi);
    return items[b[0]..b[1]];
}

""" + "\n".join(zig_ns) + "\n\n" + "\n".join(u) + "\n"
    return t


def patch_table(t):
    t = sub1(t, "            if (self.len == n) fullPanic(n);", '            if (self.len == n) {\n                rt.gate("full");\n                fullPanic(n);\n            }')
    old = "            return @intCast(rt.indexBelow(i, comptime @min(n, std.math.maxInt(usize))));"
    t = sub1(t, old, old.replace("rt.indexBelow(i,", 'rt.indexBelowK("ti", i,'))
    anchor = "        /// What a committed table's slot past `cap` reads as."
    twins = """        // CEIL: the group twins (a slot's read makes no test).
        pub const at__g = at;
        pub const constSlot__g = constSlot;
        pub const slot__g = slot;
        inline fn index__g(i: anytype) Index {
            return @intCast(rt.indexBelowK("gti", i, comptime @min(n, std.math.maxInt(usize))));
        }
        pub inline fn atInt__g(self: *const Self, i: anytype) T {
            return self.at(index__g(i));
        }
        pub inline fn constSlotInt__g(self: *const Self, i: anytype) *const T {
            return self.constSlot(index__g(i));
        }
        pub inline fn slotInt__g(self: *Self, i: anytype) *T {
            return self.slot(index__g(i));
        }

"""
    t = sub1(t, anchor, twins + anchor)
    return t


METHODS = ["at", "slot", "constSlot", "atProven", "slotProven", "constSlotProven", "atIf", "slotIf",
           "constSlotIf", "atInt", "slotInt", "constSlotInt"]
FREE = ["at", "elemPtr", "atProven", "elemPtrProven", "atIf", "elemPtrIf", "indexBelow", "slice", "sliceMut"]
METHOD_RE = re.compile(r"\.(" + "|".join(sorted(set(METHODS + FREE), key=len, reverse=True)) + r")\(")
FN_RE = re.compile(r"^(\s*)(pub )?(inline |noinline |export )?fn ([A-Za-z_][A-Za-z0-9_]*)\(")


def user_aliases(path, t):
    """A user type's own `at` (and the rest) gets a `__g` alias, so a
    renamed call reaches it unchanged."""
    out = []
    for line in t.split("\n"):
        out.append(line)
    lines = out
    res = []
    i = 0
    names = set(METHODS + FREE)
    while i < len(lines):
        line = lines[i]
        res.append(line)
        m = FN_RE.match(line)
        if m and m.group(4) in names and line.rstrip().endswith("{"):
            ind = m.group(1)
            # find the end of this fn: a line equal to ind + "}"
            j = i + 1
            while j < len(lines) and lines[j] != ind + "}":
                res.append(lines[j]); j += 1
            res.append(lines[j])
            res.append(f"{ind}pub const {m.group(4)}__g = {m.group(4)};")
            i = j + 1
            continue
        i += 1
    return "\n".join(res)


def functions(t):
    """(start, end, name) line ranges of every function, at any depth,
    whose header ends with `{`, ended by the line of its own indentation
    and `}`."""
    lines = t.split("\n")
    out = []
    for i, line in enumerate(lines):
        m = FN_RE.match(line)
        if m and line.rstrip().endswith("{"):
            ind = m.group(1)
            j = i + 1
            while j < len(lines) and lines[j] != ind + "}":
                j += 1
            out.append((i, j, m.group(4)))
    return lines, out


def apply_group(t, sel, rig, zig):
    """In the functions `sel(name)` picks: rename the index and slice
    calls to their twins (rig), and turn off Zig's safety (zig)."""
    lines, fns = functions(t)
    picked = [(s, e, n) for (s, e, n) in fns if sel(n)]
    body = set()
    for (s, e, n) in picked:
        body.update(range(s + 1, e))
    nren = 0
    if rig:
        for k in sorted(body):
            new, c = METHOD_RE.subn(lambda m: "." + m.group(1) + "__g(", lines[k])
            lines[k] = new; nren += c
    if zig:
        for (s, e, n) in picked:
            k = s
            if s + 1 < len(lines) and lines[s + 1].strip().startswith("@branchHint"):
                k = s + 1
            lines[k] = lines[k] + " @setRuntimeSafety(false);"
    return "\n".join(lines), len(picked), nren


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst")
    ap.add_argument("--off", default="")
    ap.add_argument("--groups", default="", help="JSON file: {file: [names] or '*'} for the group")
    ap.add_argument("--rig", action="store_true")
    ap.add_argument("--zig", action="store_true")
    ap.add_argument("--pad", type=int, default=0, help="a null variant: N bytes of code in a function of its own, which moves the code laid out after it")
    a = ap.parse_args()
    off = [k for k in a.off.split(",") if k]
    for k in off:
        if k not in ALL: raise SystemExit(f"unknown kind {k}")
    if os.path.exists(a.dst): shutil.rmtree(a.dst)
    shutil.copytree(a.src, a.dst, ignore=shutil.ignore_patterns(".git", ".zig-cache"))
    rt = os.path.join(a.dst, "rig/runtime.zig")
    t = open(rt).read(); open(rt, "w").write(patch_runtime(t))
    tb = os.path.join(a.dst, "rig/table.zig")
    t = open(tb).read(); open(tb, "w").write(patch_table(t))
    with open(os.path.join(a.dst, "rig/ceil.zig"), "w") as f:
        f.write("// CEIL: which kinds of check are off.\n")
        for k in ALL:
            f.write(f"pub const {k} = {'true' if k in off else 'false'};\n")
    # user aliases everywhere outside rig/
    for fn in os.listdir(a.dst):
        if fn.endswith(".zig"):
            p = os.path.join(a.dst, fn); t = open(p).read()
            t2 = user_aliases(p, t)
            if t2 != t: open(p, "w").write(t2)
    report = {"off": off, "pad": a.pad}
    if a.pad:
        rtp = os.path.join(a.dst, "rig/runtime.zig")
        with open(rtp, "a") as f:
            f.write(f"\n// CEIL: a null variant's padding, never called.\nexport fn __ceil_pad() callconv(.naked) void {{\n    asm volatile (\".skip {a.pad}, 0xcc\");\n}}\n")
    if a.groups:
        if not os.path.exists(a.groups):  # zigw runs it from rig's directory
            a.groups = os.path.join(os.path.dirname(os.path.abspath(__file__)), a.groups)
        g = json.load(open(a.groups))
        for fn, names in g.items():
            p = os.path.join(a.dst, fn); t = open(p).read()
            if names == "*": sel = lambda n: True
            else:
                ns = set(names)
                if isinstance(names, dict):  # {"not": [...]}
                    ns = set(names["not"]); sel = (lambda ns: lambda n: n not in ns)(ns)
                else: sel = (lambda ns: lambda n: n in ns)(ns)
            t, nfn, nren = apply_group(t, sel, a.rig, a.zig)
            open(p, "w").write(t)
            report[fn] = {"functions": nfn, "renamed": nren}
    json.dump(report, open(os.path.join(a.dst, "ceil.json"), "w"), indent=1)
    print(json.dumps(report))


if __name__ == "__main__":
    main()
