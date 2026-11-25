//! Typecheck's `match`: subjects, arms, patterns and what they bind, and
//! coverage.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Wide = sema.Wide;
const resolve = @import("../resolve.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Field = sema.Field;
const Error = std.mem.Allocator.Error;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const CompatCheck = @import("compat.zig");
const GenericCheck = @import("generics.zig");
const BuiltinCheck = @import("builtins.zig");
const CallCheck = @import("calls.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// `ty`, or, where it is a set parameter `E` or a view of one,
/// `error` in its place: what may be done with a value of `E` is
/// what may be done with an error of any set.
pub fn setParamAsError(self: *Checker, ty: TypeId) Error!TypeId {
    return switch (self.ctx.types.get(ty)) {
        .read_view => |inner| if (sema.isSetParam(self.ctx, inner)) self.ctx.intern(.{ .read_view = self.t().any_error_id }) else ty,
        .write_view => |inner| if (sema.isSetParam(self.ctx, inner)) self.ctx.intern(.{ .write_view = self.t().any_error_id }) else ty,
        else => if (sema.isSetParam(self.ctx, ty)) self.t().any_error_id else ty,
    };
}

pub fn checkMatch(self: *Checker, node: Sexp, position: Checker.Position, expected: ?TypeId) Error!TypeId {
    return checkMatchIn(self, node, position, expected, false);
}

/// `match` `node`, the `Bool` a `matches` is, or, with `opens`, the
/// one-arm `match` a `matches` in a condition is (`rig.asMatchOf`),
/// whose first arm's scope stays open for the rest of the condition
/// and the body. Every form checks its patterns here.
pub fn checkMatchIn(self: *Checker, node: Sexp, position: Checker.Position, expected: ?TypeId, opens: bool) Error!TypeId {
    const subject = ir.Match.subject(node);
    const saved_held = self.expect.held_base;
    defer self.expect.held_base = saved_held;
    const saved_in_place = self.expect.in_place;
    defer self.expect.in_place = saved_in_place;
    const found = try FlowCheck.checkMatchSubject(self, node);
    const mode = found.mode;
    var scrutinee = found.scrutinee;
    const subject_hands = found.hands;
    const scrut_pos = found.pos;
    var matchable = found.matchable;
    // A `matches`: its pattern, which the subject is tested against.
    const tested: Sexp = if (rig.isMatchesTest(node)) ir.Arm.pattern(ir.Match.arms(node)[0]) else .nil;
    if (tested != .nil and !self.isPoison(scrutinee) and try matchesRejects(self, subject, tested, scrutinee)) {
        scrutinee = self.t().invalid_id;
        matchable = true;
    }
    if (!matchable) {
        try self.err(scrut_pos, "cannot `match` on a value of type `{s}`; match works on enums, errors, integers, Bool, Symbol, and text", .{try self.tyName(scrutinee)});
    }

    // The place a binding that cannot be written views, for the
    // diagnostic that says how to write it.
    const viewed: ?tc.CopySource = if (mode != .read) null else if (subject.isKind(.read) and ViewCheck.hands(self, ir.Read.operand(subject)).hasStorage())
        .{ .place = ir.Read.operand(subject), .kind = .match_read, .pattern = tested }
    else if (subject_hands.hasStorage()) .{ .place = subject, .kind = .match_copy, .pattern = tested } else null;
    const saved_arm_local = self.expect.arm_local;
    defer self.expect.arm_local = saved_arm_local;
    self.expect.arm_local = mode == .read and !self.isPoison(scrutinee) and !storage.matchesInPlace(self.ctx, node);
    const saved_matching = self.expect.matching;
    defer self.expect.matching = saved_matching;
    self.expect.matching = node;
    var cov: Checker.MatchCoverage = .{ .variant_total = try BuiltinCheck.variantTotal(self, sema.unwrapViews(self.ctx, scrutinee)), .subject = scrutinee };
    var arm_values: std.ArrayList(Checker.Typed) = .empty;
    defer arm_values.deinit(self.ctx.allocator);
    defer cov.deinit(self.ctx.allocator);
    var result: ?TypeId = expected;
    const errors = matchesErrors(self, scrutinee);
    // A test whose pattern is rejected is not said to always hold too.
    const reported = self.ctx.diagnostics.items.len;

    for (ir.Match.arms(node)) |arm| {
        const prev = self.enter(arm);
        defer self.scope = prev;
        const pattern = ir.Arm.pattern(arm);
        const guard = ir.Arm.guard(arm);
        if (cov.has_default or coversAll(self, &cov, scrutinee)) {
            // The other values of a `matches`: none, so the test
            // always holds.
            if (rig.isHiddenLeaf(pattern)) {
                if (!cov.rejected and self.ctx.diagnostics.items.len == reported) try alwaysHolds(self, tested, scrutinee);
            } else try self.errAt(pattern, "this arm never runs: the arms before it cover every value", .{});
        }
        const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
        if (tested != .nil and !rig.isHiddenLeaf(pattern)) try testCatchAll(self, subject, alts, &cov);
        if (alts.len > 1) try checkAlternatives(self, alts, tested != .nil);
        if (alts.len > 1 and !self.isPoison(scrutinee) and errors) try plainAlternatives(self, alts);
        // A guarded arm may not run for the values its pattern
        // matches, so it covers none of them; later arms may repeat
        // its pattern.
        var guarded: Checker.MatchCoverage = .{ .before = &cov, .variant_total = cov.variant_total, .subject = scrutinee };
        defer guarded.deinit(self.ctx.allocator);
        const partial = guard != .nil;
        const into = if (partial) &guarded else &cov;
        into.arm_alts.clearRetainingCapacity();
        for (alts) |alt| try checkPattern(self, alt, scrutinee, into, mode);
        if (alts.len > 1) try checkAlternativeTypes(self, alts);
        if (partial) {
            var it = guarded.variants.keyIterator();
            while (it.next()) |k| try cov.guarded.put(self.ctx.allocator, k.*, {});
            var parts = guarded.parts.keyIterator();
            while (parts.next()) |k| try cov.guarded.put(self.ctx.allocator, k.*, {});
        }
        if (viewed) |v| {
            if (pattern.isKind(.variant_pattern) or pattern.isKind(.alt_pattern)) {
                for (self.ctx.armPayloadBindings(pattern)) |b| if (self.ctx.symbolOf(b)) |sym| try self.copied_from.put(self.ctx.allocator, sym, v);
            } else if (storage.isCatchAll(self.ctx, pattern)) if (self.ctx.symbolOf(pattern)) |sym| {
                var whole = v;
                whole.whole = true;
                try self.copied_from.put(self.ctx.allocator, sym, whole);
            };
        }
        if (mode == .consume) {
            const binds: []const Sexp = if (pattern.isKind(.variant_pattern) or pattern.isKind(.alt_pattern)) self.ctx.armPayloadBindings(pattern) else (&pattern)[0..1];
            for (binds) |b| if (self.ctx.symbolOf(b)) |sym| try self.owned_bindings.put(self.ctx.allocator, sym, {});
        }
        // Every read match's binding, for the hint that names the
        // match that writes (`readMatchHint`).
        if (mode == .read and viewed == null) {
            const shown_subject = if (subject.isKind(.read)) ir.Read.operand(subject) else subject;
            if (pattern.isKind(.variant_pattern) or pattern.isKind(.alt_pattern)) {
                for (self.ctx.armPayloadBindings(pattern)) |b| if (self.ctx.symbolOf(b)) |sym| try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = shown_subject, .kind = .match_read });
            } else if (pattern == .src) if (self.ctx.symbolOf(pattern)) |sym| try self.read_subjects.put(self.ctx.allocator, sym, .{ .place = shown_subject, .kind = .match_read, .whole = true });
        }
        if (guard != .nil) {
            const saved_plain = self.expect.plain_cond;
            self.expect.plain_cond = try BuiltinCheck.plainCondOf(self, guard, &.{ir.Arm.body(arm)});
            try ViewCheck.checkExpr(self, guard, self.t().bool_id);
            self.expect.plain_cond = saved_plain;
            if (CompatCheck.findMove(guard)) |m| try self.errAt(m, "a guard cannot move a value: when it fails, a later arm matches the same value", .{});
            if (guardWrite(self, guard, subject, pattern)) |w| try self.errAt(w, "a guard cannot change the value being matched: when it fails, a later arm matches the same value", .{});
        }
        const body = ir.Arm.body(arm);
        switch (position) {
            .statement => try StmtCheck.checkStmt(self, body),
            .value => if (expected) |x| try ViewCheck.checkExpr(self, body, x) else {
                const ty = try synthExpr(self, body);
                result = if (result) |r| (try BuiltinCheck.unify(self, r, ty, self.startOf(body))) orelse r else ty;
                try arm_values.append(self.ctx.allocator, .{ .node = body, .ty = ty });
            },
        }
    }
    // The pattern's names go on with the rest of the condition and
    // the body.
    if (opens) _ = self.enter(ir.Match.arms(node)[0]);

    // A binding views the subject through the body, and a temporary
    // the subject reads ends with the subject.
    if (tempBase(self, subject)) |temp| if (armsBind(self, node)) {
        try self.errAt(temp, "the pattern's bindings would outlive the temporary `{s}`, which the `match` subject drops; bind it to a name first", .{CallCheck.sourceText(self, temp)});
    };
    if (result) |r| for (arm_values.items) |av| try FlowCheck.adaptLiteral(self, av.node, av.ty, r);
    const exhaustive = coversAll(self, &cov, scrutinee);
    if (exhaustive) try self.ctx.record(.exhaustive, node, {});
    if (matchable and !cov.has_default and !cov.rejected and !exhaustive and !self.isPoison(scrutinee)) try notExhaustive(self, &cov, scrutinee, scrut_pos);
    if (position == .statement) return self.t().void_id;
    return result orelse self.t().invalid_id;
}

/// Whether a match on a value of type `scrutinee` matches errors.
pub fn matchesErrors(self: *Checker, scrutinee: TypeId) bool {
    if (self.isPoison(scrutinee)) return false;
    const matched = sema.unwrapViews(self.ctx, scrutinee);
    return matched == self.t().any_error_id or sema.isErrorSet(self.ctx, matched) or sema.isErrorUnion(self.ctx, matched);
}

/// The test `x matches P` whose pattern `pattern` matches every value
/// of `scrutinee` always holds, and is rejected: a `Bool` known when
/// compiling is `true`, and a pattern that binds is a `match`'s.
pub fn alwaysHolds(self: *Checker, pattern: Sexp, scrutinee: TypeId) Error!void {
    const reached = sema.unwrapViews(self.ctx, scrutinee);
    const binds = if (rig.matchesBinds(self.ctx.source, pattern)) "; bind its fields with `match`" else "";
    if (pattern.isKind(.variant_pattern) or pattern.isKind(.enum_lit)) if (sema.enumVariantCount(self.ctx, reached) == 1) {
        const name = self.text(ir.get(pattern, .name));
        return self.errAt(pattern, "`.{s}` is the only variant of `{s}`, so this test always holds{s}", .{ name, try self.tyName(reached), binds });
    };
    try self.errAt(pattern, "`{s}` matches every `{s}`, so this test always holds{s}", .{ try ViewCheck.plainText(self, pattern), try self.tyName(reached), binds });
}

/// `_` or a name after `matches`, alone or among alternatives, matches
/// every value: rejected, and its name given no type.
pub fn testCatchAll(self: *Checker, subject: Sexp, alts: []const Sexp, cov: *Checker.MatchCoverage) Error!void {
    for (alts) |alt| if (storage.isCatchAll(self.ctx, alt)) {
        const name = self.text(alt);
        const compare = if (std.mem.eql(u8, name, "_")) "" else try std.fmt.allocPrint(self.ctx.arena.allocator(), "; to compare with `{s}`, write `{s} == {s}`", .{ name, try ViewCheck.plainText(self, CompatCheck.stripSigil(subject)), name });
        try self.errAt(alt, "`{s}` matches every value, so `matches` would always hold; a pattern after `matches` names a variant or a value{s}", .{ name, compare });
        try poisonBinding(self, alt);
        cov.rejected = true;
    };
}

/// Whether the test of `subject`, of type `scrutinee`, for `pattern`
/// after `matches` is rejected (reported): an optional, whose value is
/// taken out first; or, for a pattern that binds a payload, a value
/// that is not an enum or an error.
pub fn matchesRejects(self: *Checker, subject: Sexp, pattern: Sexp, scrutinee: TypeId) Error!bool {
    const reached = sema.unwrapViews(self.ctx, scrutinee);
    const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(subject));
    if (self.ctx.types.get(reached) == .optional) {
        const inner = try self.tyName(self.ctx.types.get(reached).optional);
        const v: []const u8 = if (inner.len > 0 and std.ascii.isAlphabetic(inner[0])) &.{std.ascii.toLower(inner[0])} else "v";
        const pat = try ViewCheck.plainText(self, pattern);
        try self.errAt(subject, "`{s}` is a `{s}`: take the value out first (`if {s} as {s} and {s} matches {s}`)", .{ shown, try self.tyName(reached), shown, v, v, pat });
        return true;
    }
    if (rig.matchesBinds(self.ctx.source, pattern) and sema.enumVariantCount(self.ctx, reached) == null) {
        const ty = try self.tyName(reached);
        try self.errAt(subject, "`matches` with a variant pattern tests which variant an enum value is, and `{s}` is {s} `{s}`", .{ shown, CompatCheck.article(ty), ty });
        return true;
    }
    return false;
}

/// Whether every value cube `c` holds is in one of `parts`. Two cubes
/// that meet but do not nest differ on a field `c` leaves open, and
/// each half of `c` there is covered or not on its own, so the answer
/// is exact; the halves split only on a field some part tests.
/// `c` is scratch, restored on return.
pub fn cubeCovered(parts: []const Checker.Cube, c: []sema.PayloadTest) bool {
    return uncoveredCube(parts, c) == null;
}

/// A cube of values inside `c` that none of `parts` holds, in `c`
/// (left changed to it), or null when `parts` cover `c`.
pub fn uncoveredCube(parts: []const Checker.Cube, c: []sema.PayloadTest) ?[]sema.PayloadTest {
    var split: ?usize = null;
    for (parts) |p| {
        if (cubeHolds(p, c)) return null;
        if (split == null and cubesMeet(p, c)) {
            for (p, c, 0..) |pt, ct, i| if (ct == .any and pt != .any) {
                split = i;
                break;
            };
        }
    }
    const i = split orelse return c;
    for ([2]sema.PayloadTest{ .some, .none }) |half| {
        c[i] = half;
        if (uncoveredCube(parts, c)) |miss| return miss;
    }
    c[i] = .any;
    return null;
}

/// Whether cube `outer` holds every value of cube `inner`.
pub fn cubeHolds(outer: Checker.Cube, inner: Checker.Cube) bool {
    for (outer, inner) |o, i| if (o != .any and o != i) return false;
    return true;
}

/// Whether cubes `a` and `b` hold a value in common.
pub fn cubesMeet(a: Checker.Cube, b: Checker.Cube) bool {
    for (a, b) |x, y| if (x != .any and y != .any and x != y) return false;
    return true;
}

/// The pattern of the values of cube `c` of variant `name` of enum
/// `subject`, as the arms would write it: `.got(a: _?, c: none)`.
pub fn cubeText(self: *Checker, subject: TypeId, name: []const u8, c: Checker.Cube) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const fields = variantFields(self, subject, name);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, ".{s}", .{name});
    var n: usize = 0;
    for (c, 0..) |test_of, i| {
        if (test_of == .any) continue;
        try out.appendSlice(a, if (n == 0) "(" else ", ");
        n += 1;
        if (fields.len > 1) try out.print(a, "{s}: ", .{fields[i].name});
        try out.appendSlice(a, if (test_of == .some) "_?" else "none");
    }
    if (n > 0) try out.append(a, ')');
    return out.items;
}

/// The payload fields of variant `name` of enum `subject`.
pub fn variantFields(self: *Checker, subject: TypeId, name: []const u8) []const Field {
    const decl = sema.nominalDecl(self.ctx, sema.unwrapViews(self.ctx, subject)) orelse return &.{};
    for (decl.symbol().fields orelse &.{}) |f| {
        if (f.is_variant and std.mem.eql(u8, f.name, name)) return f.payload orelse &.{};
    }
    return &.{};
}

/// The first write view in guard `g` of what the match reaches: the
/// subject's binding, or a binding of the arm's `pattern`.
pub fn guardWrite(self: *Checker, g: Sexp, subject: Sexp, pattern: Sexp) ?Sexp {
    if (g != .list) return null;
    const written: ?Sexp = if (g.isKind(.write)) ir.Write.operand(g) else if (g.isKind(.cap_write)) ir.CapWrite.name(g) else null;
    if (written) |w| if (CompatCheck.placeRoot(w)) |leaf| if (self.ctx.symbolOf(leaf)) |sym| {
        if (CompatCheck.placeRoot(subject)) |s| if (self.ctx.symbolOf(s) == sym) return g;
        if (patternBinds(self, pattern, sym)) return g;
        if (self.ctx.symbols.items[sym].kind == .capture) {
            const origin = self.ctx.symbols.items[sym].origin;
            if (CompatCheck.placeRoot(subject)) |s| if (self.ctx.symbolOf(s) == origin) return g;
        }
    };
    for (g.items()) |c| if (guardWrite(self, c, subject, pattern)) |w| return w;
    return null;
}

/// The value made here that `subject`, a part of it, is a path from
/// (`mk()` in `mk().e[0]`), which a header holds for its construct;
/// `.nil` for any other subject.
pub fn madeBase(self: *Checker, subject: Sexp) Sexp {
    if (ViewCheck.hands(self, subject).kind != .part_of_made) return .nil;
    var base = subject;
    while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
    return if (ViewCheck.hands(self, base).kind == .made) base else .nil;
}

/// For binding `sym` that a read match binds to read (its access,
/// `Symbol.access`), the hint naming the match that writes through
/// it; empty for any other binding.
pub fn readMatchHint(self: *Checker, sym: ?SymbolId) Error![]const u8 {
    const id = sym orelse return "";
    const s = self.ctx.symbols.items[id];
    if (s.access != .read) return "";
    if (self.read_subjects.get(id)) |from| if (from.kind == .as) {
        const shown = try ViewCheck.plainText(self, from.place);
        // No `!` writes a field another module keeps read-only.
        if (StmtCheck.placeOf(self, from.place).read_only) |f| return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`, and field `{s}` of `{s}` is read-only {s}, so nothing here writes through it", .{ s.name, shown, f.field, f.owner, try GenericCheck.readOnlyWhere(self.ctx, f, false) });
        // A parameter taken by value is written once it is taken to
        // write (`o: !T`).
        const subject = StmtCheck.placeOf(self, from.place);
        if (subject.root == .param) {
            const param = self.ctx.symbols.items[subject.sym.?].name;
            const take = if (std.mem.eql(u8, param, "@")) try self.ctx.arena.allocator().dupe(u8, "take `!@`") else try self.ctx.arena.allocator().print("take the parameter to write (`{s}: !…`)", .{param});
            return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`: to write through it, {s}, then bind it with `if !{s} as {s}`", .{ s.name, shown, take, shown, s.name });
        }
        return self.ctx.arena.allocator().print("; `{s}` is a read view of the value inside `{s}`: to write through it, bind it with `if !{s} as {s}`", .{ s.name, shown, shown, s.name });
    };
    const from = self.copied_from.get(id) orelse self.read_subjects.get(id) orelse return "";
    if (from.kind != .match_copy and from.kind != .match_read) return "";
    const what = if (from.whole) "" else "a field of ";
    const shown = try ViewCheck.plainText(self, from.place);
    if (StmtCheck.placeOf(self, from.place).read_only) |f| return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`, and field `{s}` of `{s}` is read-only {s}, so nothing here writes through it", .{ s.name, what, shown, f.field, f.owner, try GenericCheck.readOnlyWhere(self.ctx, f, false) });
    // A subject reached through a read view or a shared handle is never
    // written through, however it is matched.
    if (readOnlyStep(self, from.place)) |why| return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`, which is reached through {s}, so nothing writes through it", .{ s.name, what, shown, why });
    return self.ctx.arena.allocator().print("; `{s}` is a read view of {s}`{s}`: to write through it, {s}", .{ s.name, what, shown, try writeMatchAdvice(self, from.place) });
}

/// What makes `subject` read-only: it, or a value on its path (the
/// base, an object of a field or element, a leaf of a branch), is a
/// read view or a shared handle, by its type; null for none.
pub fn readOnlyStep(self: *Checker, subject: Sexp) ?[]const u8 {
    var e = subject;
    while (true) {
        if (self.ctx.typeOf(e)) |ty| switch (self.ctx.types.get(ty)) {
            .read_view => return "a read view",
            .shared => return "a shared handle",
            else => {},
        };
        if (e.isKind(.member) or e.isKind(.index)) {
            e = ir.get(e, .object);
        } else if (sema.isBranchingForm(e)) {
            var leaves: std.ArrayList(Sexp) = .empty;
            defer leaves.deinit(self.ctx.allocator);
            sema.valueLeaves(self.ctx.allocator, e, &leaves) catch return null;
            for (leaves.items) |leaf| if (self.ctx.typeOf(leaf)) |ty| switch (self.ctx.types.get(ty)) {
                .read_view => return "a read view",
                .shared => return "a shared handle",
                else => {},
            };
            return null;
        } else return null;
    }
}

pub fn headerSubject(e: Sexp) Checker.HeaderSubject {
    if (e.isKind(.read)) return .{ .node = ir.get(e, .operand), .sigil = .read };
    if (e.isKind(.write)) return .{ .node = ir.get(e, .operand), .sigil = .write };
    return .{ .node = e, .sigil = null };
}

/// A header reads its subject where it stands (Core sentence 1), so a
/// branching value, or a path from one, is viewed there, by its sigil
/// or, bare, to read, and `viewsBranch` decides whether it may be: a
/// branch is a value, never a place. A bare subject the header copies
/// (plain data), or reads through a copy of a read view
/// (`readsInPlace`), is read as a value, not viewed. False when the
/// view is rejected (reported).
pub fn headerViewsBranch(self: *Checker, subject: Checker.HeaderSubject) Error!bool {
    const kind = subject.sigil orelse kind: {
        const ty = self.ctx.typeOf(subject.node) orelse return true;
        if (sema.copies(self.ctx, ty) == .yes or !ViewCheck.readsInPlace(self, subject.node)) return true;
        break :kind Checker.ViewKind.read;
    };
    return ViewCheck.viewsBranch(self, subject.node, .nil, kind);
}

/// How to write through the bindings of a read match of `subject`:
/// `match !subject`, or, for a part of a value made in the header,
/// that value bound to a name first.
pub fn writeMatchAdvice(self: *Checker, subject: Sexp) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    // A part of a branch: the branch is named first, and its part
    // matched to write (`t = (!a if c else !b)`, then `match !t.e`).
    if (subject.isKind(.member) or subject.isKind(.index)) {
        const base = sema.pathRoot(subject);
        if (sema.isBranchingForm(base)) {
            const whole = try ViewCheck.plainText(self, subject);
            const branch_text = try ViewCheck.plainText(self, base);
            // The steps after the branch, as written: `.e`, `[0].e`.
            const end = self.ctx.span(base).end;
            const start = self.ctx.span(subject).start;
            const stop = self.ctx.span(subject).end;
            const rest = if (end >= start and end <= stop) std.mem.trimStart(u8, diag.textBetween(self.ctx.source, end, stop), ")") else whole;
            return a.print("bind the branch to a name first, `t = ({s})`, then match its part with `match !t{s}`", .{ branch_text, rest });
        }
    }
    switch (ViewCheck.hands(self, subject).kind) {
        // A part of a value made in the header: the value is named
        // first.
        .part_of_made => {
            var base = subject;
            while (base.isKind(.member) or base.isKind(.index)) base = ir.get(base, .object);
            return a.print("bind `{s}` to a name first, then match its part with `match !`", .{try ViewCheck.plainText(self, base)});
        },
        .place, .view => if (StmtCheck.placeOf(self, subject).named()) return a.print("match with `match !{s}`", .{try ViewCheck.plainText(self, subject)}),
        // Each branch gets a write view: `match (!a if c else !b)`; the
        // value inside an optional gets one with `if !o as x`.
        .branches => if (subject.isKind(.@"if")) {
            return "put the `!` on each branch: `match (!a if c else !b)`";
        } else if (subject.isKind(.propagate_none)) {
            return a.print("make a write view of the value inside first, `if !{s} as x`, then match it with `match !x`", .{try ViewCheck.plainText(self, ir.PropagateNone.value(subject))});
        },
        .made, .jump, .none => {},
    }
    // A call that returns a read view writes nothing; one that
    // returns a write view is matched as it is.
    if (subject.isKind(.call)) return "match a write view instead: a place with `match !`, or a call that returns one";
    return a.print("bind `{s}` to a name first, then match it with `match !`", .{try ViewCheck.plainText(self, subject)});
}

/// Report `e` when it is a read match's binding of a payload that is
/// not plain data, which views the payload where it is, taken by
/// `verb` (`move`, `drop`). True when reported.
pub fn payloadViewTaken(self: *Checker, e: Sexp, verb: []const u8) Error!bool {
    if (e != .src) return false;
    const sym = self.ctx.symbolOf(e) orelse return false;
    const from = self.copied_from.get(sym) orelse return false;
    if (from.kind != .match_copy and from.kind != .match_read) return false;
    if (self.ctx.types.get(self.ctx.symbols.items[sym].ty) != .read_view) return false;
    const name = self.text(e);
    const shown = try ViewCheck.plainText(self, from.place);
    const place = StmtCheck.placeOf(self, from.place);
    const viewed = from.kind == .match_read or place.indirect or if (self.ctx.typeOf(from.place)) |ty| sema.isReadOrWriteView(self.ctx, ty) else false;
    const shared = if (self.ctx.typeOf(place.base)) |ty| self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .shared else false;
    if (place.root == .capture) {
        try self.errAt(e, "cannot {s} captured resource `{s}`: `{s}` views a payload of it, and a closure never gives up what it captured", .{ verb, CallCheck.sourceText(self, place.base), name });
    } else if (shared) {
        try self.errAt(e, "cannot {s} out of `{s}`: `{s}` is a shared handle, which only reads its value", .{ verb, name, CallCheck.sourceText(self, place.base) });
    } else if (viewed or place.root == .temporary) {
        try self.errAt(e, "cannot {s} out of `{s}`: it is a view of `{s}`", .{ verb, name, CallCheck.sourceText(self, place.base) });
    } else try self.errAt(e, "cannot {s} `{s}` out of `{s}`: `match {s}` reads `{s}`; write `match <{s}` to take its fields", .{ verb, name, shown, shown, shown, shown });
    return true;
}

/// The held base turns out to hold nothing (its part is plain data):
/// it is read in the header as a temporary, as any made value is.
pub fn releaseHeld(self: *Checker) Error!void {
    const base = self.expect.held_base;
    self.expect.held_base = .nil;
    try self.ctx.forgetUse(base);
    try ViewCheck.readLeaf(self, base);
}

/// Whether the header over `subject` may hold its base for the
/// construct: the base makes no statement temporary, which would
/// end with the header while the held value, and what it views,
/// lives on. Reported when not.
pub fn holdsHeld(self: *Checker, subject: Sexp) Error!bool {
    const base = self.expect.held_base;
    if (!makesTemps(self, base, base)) return true;
    try self.errAt(subject, "this header holds `{s}` for its construct, but a temporary made inside it ends with the header; bind `{s}` to a name first", .{ CallCheck.sourceText(self, base), CallCheck.sourceText(self, base) });
    return false;
}

/// Whether `node`, inside the held base `base`, is or holds a
/// statement temporary (`dropsTemp`).
pub fn makesTemps(self: *Checker, node: Sexp, base: Sexp) bool {
    if (node != .list) return false;
    if (!CompatCheck.sameNode(node, base) and self.ctx.dropsTemp(node)) return true;
    for (node.items()) |item| if (makesTemps(self, item, base)) return true;
    return false;
}

/// Header `node` (a `match`, a `for`, or an `as`) over `subject` that
/// makes a statement temporary (`sema.firstStmtTemp`) is evaluated by
/// emit in a block that ends the temporary. The block yields the
/// address of a place the subject reaches (`storage.headerPoints`),
/// and the construct binds the place's own, as it would with no
/// temporary. It yields the value of any other subject, and what the
/// construct binds is in that copy, which is recorded (the storage
/// fact `header_copy`) for emit. A header that copies is rejected at
/// the temporary, whatever it binds: a write, a Cell change, or a
/// view, a catch-all's of plain data included, would reach the copy.
/// A value made here, which no name holds, is the construct's own: it
/// binds plain data of it by copy, which is what the copy holds.
pub fn rejectHeaderCopy(self: *Checker, node: Sexp, subject: Sexp, bound: TypeId) Error!void {
    const temp = sema.firstStmtTemp(self.ctx, subject) orelse return;
    if (storage.headerPoints(self.ctx, storage.headerSubject(node))) return;
    try self.ctx.record(.header_copies, node, {});
    if (self.isPoison(bound)) return;
    if (ViewCheck.hands(self, subject).kind == .made and sema.holdsNoLoanButText(self.ctx, sema.unwrapViews(self.ctx, bound))) return;
    if (CompatCheck.inIndex(subject, temp)) {
        try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind the index to a name first", .{});
    } else if (CompatCheck.inArgument(subject, temp)) {
        try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind the argument to a name first", .{});
    } else try self.errAt(temp, "this header binds a copy of its subject, since a temporary it makes ends with the header: bind `{s}` to a name first", .{CallCheck.sourceText(self, temp)});
}

/// The temporary place `e` reads into, where `e` is a field or
/// element path, or a view, of one (`mk().e`, `?mk()`).
pub fn tempBase(self: *Checker, e: Sexp) ?Sexp {
    if (!ViewCheck.hands(self, e).hasStorage()) return null;
    const base = StmtCheck.placeOf(self, e).base;
    if (base != .list or !self.ctx.dropsTemp(base)) return null;
    return base;
}

/// Whether an arm of `match` binds a name that views the matched
/// value: one that is not plain data copied out of it.
pub fn armsBind(self: *Checker, match: Sexp) bool {
    for (ir.Match.arms(match)) |arm| {
        const pattern = ir.Arm.pattern(arm);
        const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
        for (alts) |alt| {
            if (storage.isCatchAll(self.ctx, alt) and viewsMatched(self, alt)) return true;
            if (alt.isKind(.variant_pattern)) for (self.ctx.payloadBindings(alt) orelse &.{}) |b| if (b == .src and viewsMatched(self, b)) return true;
        }
    }
    return false;
}

pub fn viewsMatched(self: *Checker, binding: Sexp) bool {
    const sym = self.ctx.symbolOf(binding) orelse return false;
    const ty = self.ctx.symbols.items[sym].ty;
    return !sema.holdsNoLoanButText(self.ctx, ty) or sema.mayHoldView(self.ctx, ty);
}

/// Whether `pattern` binds symbol `sym`.
pub fn patternBinds(self: *Checker, pattern: Sexp, sym: SymbolId) bool {
    if (pattern == .src) return self.ctx.symbolOf(pattern) == sym;
    if (!pattern.isKind(.variant_pattern) and !pattern.isKind(.alt_pattern)) return false;
    for (self.ctx.armPayloadBindings(pattern)) |b| if (b == .src and self.ctx.symbolOf(b) == sym) return true;
    return false;
}

/// `a, b => ...`: each alternative is a literal, range, or variant;
/// none matches everything, and they bind names only when every one
/// binds the same names (`checkAlternativeTypes` checks their types).
pub fn checkAlternatives(self: *Checker, alts: []const Sexp, in_test: bool) Error!void {
    // After `matches`, a catch-all is reported as the test it makes
    // (`testCatchAll`).
    for (alts) |alt| {
        if (!in_test and storage.isCatchAll(self.ctx, alt)) {
            try self.errAt(alt, "`{s}` matches every value, so the other alternatives never matter; give it an arm of its own", .{self.text(alt)});
            try poisonBinding(self, alt);
        }
    }
    // Each alternative's names, against the first's.
    const first = alts[0];
    for (alts[1..]) |alt| {
        if (try nameMissing(self, first, alt)) |name| return rejectAltNames(self, alts, first, alt, name);
        if (try nameMissing(self, alt, first)) |name| return rejectAltNames(self, alts, alt, first, name);
    }
}

/// Alternatives of an error, or of anything but an enum, bind no
/// names: each error's fields are read through its own set.
pub fn plainAlternatives(self: *Checker, alts: []const Sexp) Error!void {
    for (alts) |alt| for (altNames(alt)) |bound| {
        const b = sema.bindingName(bound);
        if (b != .src or std.mem.eql(u8, self.text(b), "_")) continue;
        try self.errAt(b, "alternatives of an error bind no names: write `_`, or give each alternative an arm of its own", .{});
        try poisonBinding(self, b);
        return;
    };
}

/// A name alternative `has` binds that `lacks` does not.
pub fn nameMissing(self: *Checker, has: Sexp, lacks: Sexp) Error!?Sexp {
    for (altNames(has)) |bound| {
        const b = sema.bindingName(bound);
        if (b != .src or std.mem.eql(u8, self.text(b), "_")) continue;
        const name = self.text(b);
        const found = for (altNames(lacks)) |o| {
            const n = sema.bindingName(o);
            if (n == .src and std.mem.eql(u8, self.text(n), name)) break true;
        } else false;
        if (!found) return b;
    }
    return null;
}

pub fn rejectAltNames(self: *Checker, alts: []const Sexp, has: Sexp, lacks: Sexp, name: Sexp) Error!void {
    try self.errAt(lacks, "`{s}` is bound by `{s}` but not by `{s}`: every alternative must bind the same names", .{ self.text(name), try ViewCheck.plainText(self, has), try ViewCheck.plainText(self, lacks) });
    for (alts) |alt| for (altNames(alt)) |b| try poisonBinding(self, sema.bindingName(b));
}

/// The names a variant alternative binds, `_` aside, as written.
pub fn altNames(alt: Sexp) []const Sexp {
    if (!alt.isKind(.variant_pattern)) return &.{};
    return ir.VariantPattern.bindings(alt);
}

/// Alternatives that bind a name bind it with one type: the field
/// each binds is of the same type in every one.
pub fn checkAlternativeTypes(self: *Checker, alts: []const Sexp) Error!void {
    // Alternatives of one variant, which test its optional fields
    // apart, bind each name to one field: emit reads a binding by the
    // variant the value holds.
    for (alts, 0..) |alt, i| for (alts[i + 1 ..]) |other| {
        if (!alt.isKind(.variant_pattern) or !other.isKind(.variant_pattern)) continue;
        if (!std.mem.eql(u8, self.text(rig.variantPatternName(alt)), self.text(rig.variantPatternName(other)))) continue;
        const fields = self.ctx.payloadBindings(alt) orelse continue;
        const others = self.ctx.payloadBindings(other) orelse continue;
        for (fields, 0..) |b, at| {
            if (b != .src or std.mem.eql(u8, self.text(b), "_")) continue;
            for (others, 0..) |o, at_other| {
                if (at_other == at or o != .src or !std.mem.eql(u8, self.text(o), self.text(b))) continue;
                const set = self.ctx.typeOf(alt) orelse continue;
                const v = (try sema.lookupVariant(self.ctx, set, self.text(rig.variantPatternName(alt)))) orelse continue;
                try self.errAt(o, "`{s}` is field `{s}` in `{s}` and field `{s}` in `{s}`: alternatives of one variant bind each name to one field", .{ self.text(b), v.payload[at].name, try ViewCheck.plainText(self, alt), v.payload[at_other].name, try ViewCheck.plainText(self, other) });
                try poisonBinding(self, b);
                return;
            }
        }
    };
    const first = for (alts) |alt| {
        if (alt.isKind(.variant_pattern) and self.ctx.payloadBindings(alt) != null) break alt;
    } else return;
    for (self.ctx.payloadBindings(first).?) |b| {
        if (b != .src or std.mem.eql(u8, self.text(b), "_")) continue;
        const ty = self.ctx.payloadFieldOf(b) orelse continue;
        for (alts) |alt| {
            if (alt.list.id == first.list.id or !alt.isKind(.variant_pattern)) continue;
            for (self.ctx.payloadBindings(alt) orelse continue) |o| {
                if (o != .src or !std.mem.eql(u8, self.text(o), self.text(b))) continue;
                const other = self.ctx.payloadFieldOf(o) orelse continue;
                if (other == ty) continue;
                try self.errAt(o, "`{s}` is {s} `{s}` in `{s}` and {s} `{s}` in `{s}`: alternatives bind each name with one type", .{ self.text(b), CompatCheck.article(try self.tyName(ty)), try self.tyName(ty), try ViewCheck.plainText(self, first), CompatCheck.article(try self.tyName(other)), try self.tyName(other), try ViewCheck.plainText(self, alt) });
                try poisonBinding(self, b);
                return;
            }
        }
    }
}

/// Give a rejected pattern binding no type, so its uses report
/// nothing more.
pub fn poisonBinding(self: *Checker, b: Sexp) Error!void {
    const sym = self.ctx.symbolOf(b) orelse return;
    (try self.ctx.symbolMut(sym)).ty = self.t().invalid_id;
}

/// Whether the arms so far match every value of the scrutinee type.
pub fn coversAll(self: *Checker, cov: *Checker.MatchCoverage, scrutinee: TypeId) bool {
    const ty = sema.unwrapViews(self.ctx, scrutinee);
    if (cov.variant_total) |total| return cov.variants.count() >= total;
    switch (self.ctx.types.get(ty)) {
        .bool => return cov.bools[0] and cov.bools[1],
        .int, .int_literal => {
            const bounds = CompatCheck.intBounds(if (self.ctx.types.get(ty) == .int) self.ctx.types.get(ty).int else .{});
            var next = bounds.min;
            const max = bounds.max;
            for (cov.ints.items) |iv| {
                if (iv[0] > next) return false;
                if (iv[1] >= next) next = iv[1] + 1;
                if (next > max) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// A `match` whose arms miss some values: the error names what they
/// miss, the first few variants or the least integer.
pub fn notExhaustive(self: *Checker, cov: *const Checker.MatchCoverage, scrutinee: TypeId, pos: u32) Error!void {
    const ty = sema.unwrapViews(self.ctx, scrutinee);
    const fix = "add an arm for it, or `_ =>` for the rest";
    if (CompatCheck.isText(self.ctx, ty)) return self.err(pos, "`match` on text is not exhaustive without `_ =>`: no set of strings covers every text", .{});
    if (sema.nominalDecl(self.ctx, ty)) |decl| if (decl.symbol().fields) |fields| {
        var missing: std.ArrayList(u8) = .empty;
        const a = self.ctx.arena.allocator();
        var count: usize = 0;
        for (fields) |f| {
            if (!f.is_variant or cov.variants.contains(f.name)) continue;
            count += 1;
            if (count > 4) continue;
            if (count > 1) try missing.appendSlice(a, ", ");
            // Part of a variant: values its arms miss.
            if (cov.parts.get(f.name)) |parts| {
                const whole = try a.alloc(sema.PayloadTest, parts.items[0].len);
                @memset(whole, .any);
                try missing.print(a, "`{s}`", .{try cubeText(self, ty, f.name, uncoveredCube(parts.items, whole).?)});
                continue;
            }
            try missing.print(a, "`.{s}`{s}", .{ f.name, if (cov.guarded.contains(f.name)) " (its arm has a guard)" else "" });
        }
        if (count > 4) try missing.print(a, ", and {d} more", .{count - 4});
        if (count > 0) return self.err(pos, "`match` is not exhaustive: it misses {s}; {s}", .{ missing.items, if (count > 1) "add an arm for each, or `_ =>` for the rest" else fix });
    };
    switch (self.ctx.types.get(ty)) {
        .bool => return self.err(pos, "`match` is not exhaustive: it misses {s}; {s}", .{ if (cov.bools[0]) "`true`" else if (cov.bools[1]) "`false`" else "`true` and `false`", fix }),
        .int, .int_literal => {
            // The least value missed that is not negative, else the
            // greatest negative one.
            const bounds = CompatCheck.intBounds(if (self.ctx.types.get(ty) == .int) self.ctx.types.get(ty).int else .{});
            var next: Wide = @max(bounds.min, 0);
            for (cov.ints.items) |iv| {
                if (iv[0] > next) break;
                if (iv[1] >= next) next = iv[1] + 1;
            }
            if (next > bounds.max) {
                next = -1;
                var i = cov.ints.items.len;
                while (i > 0) : (i -= 1) {
                    const iv = cov.ints.items[i - 1];
                    if (iv[1] < next) break;
                    if (iv[0] <= next) next = iv[0] - 1;
                }
            }
            return self.err(pos, "`match` on `{s}` is not exhaustive: it misses `{d}`; {s}", .{ try self.tyName(scrutinee), next, fix });
        },
        .symbol => return self.err(pos, "`match` on a `Symbol` is not exhaustive without `_ =>`: a symbol's values are every symbol the program writes", .{}),
        else => return self.err(pos, "`match` on `{s}` is not exhaustive; add `_ =>` for the values its arms miss", .{try self.tyName(ty)}),
    }
}

/// Record an integer interval a pattern matches; it may not overlap
/// an earlier one. It joins an interval it touches, so a run of
/// values is one interval and `coversAll` reads past it at once.
pub fn coverInts(self: *Checker, cov: *Checker.MatchCoverage, lo: Wide, hi: Wide, pos: u32) Error!void {
    if (cov.overlapsInts(lo, hi)) return self.err(pos, "this pattern overlaps an earlier arm", .{});
    const ints = &cov.ints;
    const at = Checker.MatchCoverage.intsAfter(ints.items, lo);
    const joins_next = at < ints.items.len and ints.items[at][0] == hi + 1;
    if (at > 0 and ints.items[at - 1][1] + 1 == lo) {
        const prev = &ints.items[at - 1];
        prev[1] = if (joins_next) ints.items[at][1] else hi;
        if (joins_next) _ = ints.orderedRemove(at);
    } else if (joins_next) {
        ints.items[at][0] = lo;
    } else try ints.insert(self.ctx.allocator, at, .{ lo, hi });
}

pub fn checkPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage, mode: tc.MatchMode) Error!void {
    switch (pattern) {
        .src => {
            const name = self.text(pattern);
            if (sema.isStringLiteralText(name)) {
                if (CompatCheck.isU8(self.ctx, sema.unwrapViews(self.ctx, scrutinee))) return checkBytePattern(self, pattern, scrutinee, cov);
                return checkTextPattern(self, pattern, scrutinee, cov);
            }
            if (CompatCheck.isLiteralText(name)) {
                try ViewCheck.checkExpr(self, pattern, scrutinee);
                if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
                    const i: usize = if (name[0] == 't') 1 else 0;
                    if (cov.hasBool(i)) try self.errAt(pattern, "this pattern overlaps an earlier arm", .{});
                    cov.bools[i] = true;
                } else if (ExprCheck.constInt(self, pattern)) |v| try coverInts(self, cov, v, v, pattern.src.pos);
                return;
            }
            if (sema.patternConst(self.ctx, pattern)) |c| return BuiltinCheck.checkConstPattern(self, pattern, try synthExpr(self, pattern), scrutinee, cov, c);
            cov.has_default = true;
            if (resolve.leafBinds(self.ctx.source, pattern)) {
                if (self.ctx.symbolOf(pattern)) |sym| {
                    // A binding that is no plain data of a copy of the
                    // subject, or captured as a copy, is usable in its
                    // arm only.
                    const ty = try bindMatchView(self, pattern, mode, scrutinee);
                    const copied = self.expect.arm_local or (mode == .read and !storage.catchAllCaptured(self.ctx, pattern, self.expect.matching));
                    if (copied and mode == .read and sema.copies(self.ctx, sema.unwrapViews(self.ctx, scrutinee)) != .yes) (try self.ctx.symbolMut(sym)).flags.arm_view = true;
                    try self.ctx.recordType(pattern, ty);
                }
            }
        },
        .list => {
            const h = pattern.kind() orelse return;
            switch (h) {
                .enum_lit => {
                    const name = ir.EnumLit.name(pattern);
                    // Against any error, `.name` is the member of the
                    // one error set that has it.
                    if (sema.isErrorUnion(self.ctx, sema.unwrapViews(self.ctx, scrutinee))) {
                        const union_ty = sema.unwrapViews(self.ctx, scrutinee);
                        const set = try BuiltinCheck.unionMemberSet(self, union_ty, name);
                        try self.ctx.recordType(pattern, set);
                        if (self.isPoison(set)) {
                            cov.rejected = true;
                            return;
                        }
                        return recordCovered(self, try BuiltinCheck.errorArmKey(self, union_ty, set, self.text(name)), null, self.startOf(pattern), cov);
                    }
                    if (sema.unwrapViews(self.ctx, scrutinee) == self.t().any_error_id) {
                        const set = try BuiltinCheck.resolveErrorName(self, name);
                        try self.ctx.recordType(pattern, set);
                        if (!self.isPoison(set)) try recordCovered(self, try BuiltinCheck.errorArmKey(self, self.t().any_error_id, set, self.text(name)), null, self.startOf(pattern), cov);
                        return;
                    }
                    if (!self.isPoison(scrutinee) and (try sema.lookupVariant(self.ctx, scrutinee, self.text(name))) == null) {
                        try reportMissingVariant(self, scrutinee, self.text(name), srcPos(name, 0));
                    }
                    try self.ctx.recordType(pattern, scrutinee);
                    try recordCovered(self, self.text(name), null, self.startOf(pattern), cov);
                },
                // `:name`: one value of the program's symbols, which
                // no set of arms covers.
                .symbol => {
                    try ViewCheck.checkExpr(self, pattern, scrutinee);
                    const key = try std.fmt.allocPrint(self.ctx.arena.allocator(), ":{s}", .{self.text(ir.Symbol.name(pattern))});
                    if (cov.variantAt(key)) |first| {
                        try self.err(self.startOf(pattern), "duplicate arm for symbol `{s}`", .{key});
                        try self.note(first, "first arm here", .{});
                    } else try cov.variants.put(self.ctx.allocator, key, self.startOf(pattern));
                },
                .member => try BuiltinCheck.checkQualifiedPattern(self, pattern, scrutinee, cov),
                .variant_pattern => try checkVariantPattern(self, pattern, scrutinee, cov, mode),
                .range_pattern => try checkRangePattern(self, pattern, scrutinee, cov),
                .set_pattern => try BuiltinCheck.checkSetPattern(self, pattern, scrutinee, cov),
                else => {
                    try ViewCheck.checkExpr(self, pattern, scrutinee);
                    if (ExprCheck.constInt(self, pattern)) |v| try coverInts(self, cov, v, v, self.startOf(pattern));
                },
            }
        },
        else => {},
    }
}

/// A string as a pattern matches text with the same bytes: the
/// subject is a `String`, a `?String`, or a `Static`. No set of
/// strings covers every text, so the match needs `_`; a string an
/// earlier arm matches, however it is written, is reported.
/// A string pattern against a `U8` is its byte (`byteString`).
pub fn checkBytePattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage) Error!void {
    const ty = sema.unwrapViews(self.ctx, scrutinee);
    try ViewCheck.checkExpr(self, pattern, ty);
    if (self.isPoison(self.ctx.typeOf(pattern) orelse self.t().invalid_id)) {
        cov.rejected = true;
        return;
    }
    const bytes = CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), self.text(pattern)) orelse return;
    try coverInts(self, cov, bytes[0], bytes[0], pattern.src.pos);
}

pub fn checkTextPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage) Error!void {
    try self.ctx.recordType(pattern, self.t().static_id);
    const mark = self.ctx.diagnostics.items.len;
    try ExprCheck.checkEscapes(self, pattern);
    const subject = sema.unwrapViews(self.ctx, scrutinee);
    if (self.isPoison(subject)) return;
    if (!CompatCheck.isText(self.ctx, subject)) {
        try self.errAt(pattern, "`{s}` is a string, which matches text: a `String`, a `?String`, or a `Static`; the subject is `{s}`", .{ self.text(pattern), try self.tyName(scrutinee) });
        cov.rejected = true;
        return;
    }
    if (self.ctx.diagnostics.items.len > mark) return;
    const bytes = CompatCheck.textLiteralBytes(self.ctx.arena.allocator(), self.text(pattern)) orelse return;
    const key = try std.fmt.allocPrint(self.ctx.arena.allocator(), "\"{s}", .{bytes});
    if (cov.variantAt(key)) |first| {
        try self.errAt(pattern, "duplicate arm for `{s}`: an earlier arm matches the same text", .{self.text(pattern)});
        try self.note(first, "first arm here", .{});
    } else try cov.variants.put(self.ctx.allocator, key, self.startOf(pattern));
}

/// `lo..hi` matches `lo` up to, not including, `hi`, like every range.
/// Both bounds are constant integers; `hi` may be one past the
/// scrutinee type's largest value, so a range can reach it.
pub fn checkRangePattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage) Error!void {
    const lo_node = ir.RangePattern.lo(pattern);
    const pos = self.startOf(lo_node);
    try ViewCheck.checkExpr(self, lo_node, scrutinee);
    const hi_node = ir.RangePattern.hi(pattern);
    // A half-open range's end may be one past the largest value; an
    // inclusive one's is a value.
    const inclusive = rig.isInclusive(pattern);
    const hi_literal = !inclusive and CompatCheck.isIntLiteralNode(self.ctx.source, hi_node);
    const st = self.ctx.types.get(sema.unwrapViews(self.ctx, scrutinee));
    if (hi_literal and (st == .int or st == .int_literal)) {
        // Record the bound's type without the fit check a value gets.
        const bound_ty = if (st == .int) sema.unwrapViews(self.ctx, scrutinee) else self.t().int_id;
        try self.ctx.recordType(hi_node, bound_ty);
        if (hi_node.isKind(.neg)) try self.ctx.recordType(ir.Neg.operand(hi_node), bound_ty);
    } else try ViewCheck.checkExpr(self, hi_node, scrutinee);
    if (self.isPoison(scrutinee)) return;
    // A bound already reported (a string of more than one byte).
    for ([2]Sexp{ lo_node, hi_node }) |b| if (self.isPoison(self.ctx.typeOf(b) orelse self.t().int_id)) return;
    const lo = ExprCheck.constInt(self, lo_node);
    const hi = ExprCheck.constInt(self, hi_node);
    if (lo == null or hi == null) {
        if (try self.perTarget(pattern, "the bounds of a range pattern")) return;
        try self.err(pos, "the bounds of a range pattern must be constant integers", .{});
        return;
    }
    if (inclusive) {
        if (lo.? > hi.?) {
            try self.err(pos, "empty range `{d}..={d}`: a range pattern `lo..=hi` matches from its start through its end", .{ lo.?, hi.? });
            return;
        }
        return coverInts(self, cov, lo.?, hi.?, pos);
    }
    if (st == .int) {
        const b = CompatCheck.intBounds(st.int);
        if (hi.? > b.max + 1 or hi.? <= b.min) {
            try self.errAt(hi_node, "the end of range `{d}..{d}` does not fit `{s}`; it may be at most {d}, one past the largest value", .{ lo.?, hi.?, try self.tyName(scrutinee), b.max + 1 });
            return;
        }
    }
    if (lo.? >= hi.?) {
        try self.err(pos, "empty range `{d}..{d}`: a range pattern matches from its start up to, not including, its end", .{ lo.?, hi.? });
        return;
    }
    try coverInts(self, cov, lo.?, hi.? - 1, pos);
}

/// Record that an alternative at `pos` matches the values `cube`
/// tests of key `name` (null: every value of it). It may match no
/// value an earlier alternative of its arm does, and some value no
/// earlier arm covers.
pub fn recordCovered(self: *Checker, name: []const u8, cube: ?Checker.Cube, pos: u32, cov: *Checker.MatchCoverage) Error!void {
    const a = self.ctx.arena.allocator();
    for (cov.arm_alts.items) |alt| {
        if (!std.mem.eql(u8, alt.name, name)) continue;
        if (alt.cube != null and cube != null and !cubesMeet(alt.cube.?, cube.?)) continue;
        if (alt.cube == null and cube == null) {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            try self.note(alt.pos, "first arm here", .{});
        } else try self.err(pos, "this alternative matches values an earlier one does: `{s}` and `{s}` both match `{s}`; alternatives match different values", .{ try cubeOrName(self, cov.subject, name, alt.cube), try cubeOrName(self, cov.subject, name, cube), try cubeText(self, cov.subject, name, try meetOf(a, alt.cube, cube, fieldCount(self, cube, alt.cube))) });
        return;
    }
    try cov.arm_alts.append(self.ctx.allocator, .{ .name = name, .cube = cube, .pos = pos });
    var parts: std.ArrayList(Checker.Cube) = .empty;
    try cov.partsOf(name, a, &parts);
    if (cov.variantAt(name)) |first| {
        if (cube == null and parts.items.len == 0) {
            try self.err(pos, "duplicate arm for variant `{s}`", .{name});
            return self.note(first, "first arm here", .{});
        }
        return self.err(pos, "this arm never runs: the arms before it cover every value of `{s}`", .{try cubeOrName(self, cov.subject, name, cube)});
    }
    if (parts.items.len > 0) {
        const whole = try a.alloc(sema.PayloadTest, parts.items[0].len);
        if (cube) |c| @memcpy(whole, c) else @memset(whole, .any);
        if (cubeCovered(parts.items, whole)) return self.err(pos, "this arm never runs: the arms before it cover every value of `{s}`", .{try cubeOrName(self, cov.subject, name, cube)});
    }
    const c = cube orelse return cov.variants.put(self.ctx.allocator, name, pos);
    const got = try cov.parts.getOrPut(self.ctx.allocator, name);
    if (!got.found_existing) got.value_ptr.* = .empty;
    try got.value_ptr.append(self.ctx.allocator, c);
    // The parts may now cover the whole variant.
    try parts.append(a, c);
    const whole = try a.alloc(sema.PayloadTest, c.len);
    @memset(whole, .any);
    if (cubeCovered(parts.items, whole)) try cov.variants.put(self.ctx.allocator, name, pos);
}

/// The pattern of cube `c` of variant `name`, or `.name` for the whole
/// variant.
pub fn cubeOrName(self: *Checker, subject: TypeId, name: []const u8, c: ?Checker.Cube) Error![]const u8 {
    if (c) |cube| return cubeText(self, subject, name, cube);
    return std.fmt.allocPrint(self.ctx.arena.allocator(), ".{s}", .{name});
}

/// The fields of the variant of cubes `a` and `b`, one of which is known.
pub fn fieldCount(_: *Checker, a: ?Checker.Cube, b: ?Checker.Cube) usize {
    return if (a) |c| c.len else if (b) |c| c.len else 0;
}

/// The values cubes `a` and `b` (null: every value) both hold.
pub fn meetOf(arena: std.mem.Allocator, a: ?Checker.Cube, b: ?Checker.Cube, len: usize) Error!Checker.Cube {
    const out = try arena.alloc(sema.PayloadTest, len);
    @memset(out, .any);
    for ([2]?Checker.Cube{ a, b }) |c| if (c) |cube| for (out, cube) |*o, test_of| {
        if (test_of != .any) o.* = test_of;
    };
    return out;
}

pub fn checkVariantPattern(self: *Checker, pattern: Sexp, scrutinee: TypeId, cov: *Checker.MatchCoverage, mode: tc.MatchMode) Error!void {
    const name = rig.variantPatternName(pattern);
    const vname = self.text(name);
    const vpos = name.src.pos;
    const bindings = ir.VariantPattern.bindings(pattern);
    // The set the member is of: the one its pattern names, or the
    // subject's; where the subject may be of several sets, the one
    // that has it. Recorded as the pattern's type.
    const subject = sema.unwrapViews(self.ctx, scrutinee);
    const several = subject == self.t().any_error_id or sema.isErrorUnion(self.ctx, subject);
    const set = (try variantPatternSet(self, pattern, subject, several)) orelse {
        cov.rejected = true;
        for (bindings) |b| try poisonBinding(self, sema.bindingName(b));
        return;
    };
    try self.ctx.recordType(pattern, set);
    const key = if (several) try BuiltinCheck.errorArmKey(self, subject, set, vname) else vname;
    const resolved = (try sema.lookupVariant(self.ctx, set, vname)) orelse {
        try recordCovered(self, key, null, vpos, cov);
        try reportMissingVariant(self, scrutinee, vname, vpos);
        for (bindings) |b| try poisonBinding(self, sema.bindingName(b));
        return;
    };
    if (bindsNothing(self, pattern)) {
        try recordCovered(self, key, null, vpos, cov);
        return self.errAt(pattern, "`{s}` binds nothing: write `{s}`", .{ CallCheck.sourceText(self, pattern), patternHead(self, pattern) });
    }
    if (resolved.payload.len == 0) {
        try recordCovered(self, key, null, vpos, cov);
        if (bindings.len > 0) try self.err(vpos, "variant `{s}` has no payload to destructure", .{vname});
        for (bindings) |b| try poisonBinding(self, sema.bindingName(b));
        return;
    }
    const written = (try fieldBindings(self, pattern, resolved.payload)) orelse {
        try recordCovered(self, key, null, vpos, cov);
        for (bindings) |b| try poisonBinding(self, sema.bindingName(b));
        return;
    };
    // `r?` binds an optional field's value and `none` tests it holds
    // none: each is recorded as its test, and the binding as the
    // name it binds, or `.nil`.
    const binds = try payloadTestsOf(self, pattern, written, resolved.payload);
    try self.ctx.record(.payload_binds, pattern, binds);
    const tests = self.ctx.payloadTests(pattern);
    // An error's member carries its fields in the error's bytes, read
    // whole: a pattern binds an optional field and does not test it.
    if (tests != null and matchesErrors(self, scrutinee)) {
        for (written) |w| if (w.isKind(.some_pattern) or w.isKind(.none_pattern)) {
            const shown = if (w.isKind(.some_pattern)) self.text(ir.SomePattern.name(w)) else "v";
            const bind = if (std.mem.eql(u8, shown, "_")) "v" else shown;
            try self.errAt(w, "`{s}` tests an optional field of an error, which a pattern cannot: bind it as `{s}`, then test `{s} == none`", .{ try ViewCheck.plainText(self, w), bind, bind });
            break;
        };
        cov.rejected = true;
        for (bindings) |b| try poisonBinding(self, sema.bindingName(b));
        return;
    }
    try recordCovered(self, key, tests, vpos, cov);
    for (binds, resolved.payload, 0..) |b, f, i| {
        // A field the pattern leaves out is read as a `_` field is.
        if (b == .nil) {
            // Read where the match reads in place when no instance
            // copies it.
            continue;
        }
        // `r?` binds the value inside the optional field.
        const field_ty = if (tests != null and tests.?[i] == .some and self.ctx.types.get(f.ty) == .optional) self.ctx.types.get(f.ty).optional else f.ty;
        // The binding's type follows its access (`bindMatchView`).
        const view = !sema.isReadOrWriteView(self.ctx, field_ty) and self.ctx.types.get(field_ty) != .slice and !self.isPoison(field_ty);
        const ty = try bindMatchView(self, b, mode, field_ty);
        try self.ctx.recordType(b, ty);
        if (!self.isPoison(field_ty)) try self.ctx.record(.payload_fields, b, field_ty);
        if (self.ctx.symbolOf(b)) |sym| {
            // A binding that is no plain data of a copy of the
            // subject is usable in its arm only.
            if (self.expect.arm_local and mode == .read and view and sema.copies(self.ctx, field_ty) != .yes) (try self.ctx.symbolMut(sym)).flags.arm_view = true;
        }
    }
}

/// The bindings `written` of variant pattern `pattern`, in the order
/// of `fields`, with each `r?` the name it binds and each `none`
/// `.nil`, recording what each tests (`sema.SemContext.payloadTests`).
/// A test of a field that is not optional is reported.
pub fn payloadTestsOf(self: *Checker, pattern: Sexp, written: []const Sexp, fields: []const Field) Error![]const Sexp {
    var tested = false;
    for (written) |b| {
        if (b.isKind(.some_pattern) or b.isKind(.none_pattern)) tested = true;
    }
    if (!tested) return written;
    const a = self.ctx.arena.allocator();
    const binds = try a.dupe(Sexp, written);
    const tests = try a.alloc(sema.PayloadTest, written.len);
    for (binds, tests, fields) |*b, *test_of, f| {
        test_of.* = .any;
        if (!b.isKind(.some_pattern) and !b.isKind(.none_pattern)) continue;
        const some = b.isKind(.some_pattern);
        const shown = try ViewCheck.plainText(self, b.*);
        const name = if (some) ir.SomePattern.name(b.*) else Sexp.nil;
        if (!self.isPoison(f.ty) and self.ctx.types.get(f.ty) != .optional) {
            try self.errAt(b.*, "`{s}` tests an optional field, and `{s}` is a `{s}`; bind it as `{s}`", .{ shown, f.name, try self.tyName(f.ty), if (some) self.text(name) else "_" });
            if (some) try poisonBinding(self, name);
            b.* = if (some) name else .nil;
            continue;
        }
        test_of.* = if (some) .some else .none;
        b.* = name;
    }
    try self.ctx.record(.payload_tests, pattern, tests);
    return binds;
}

/// How the match being checked reaches what its bindings bind
/// (`sema.MatchReach`): it writes, takes, holds a value made there
/// whole, or reads a value another holds.
pub fn matchReach(self: *Checker, mode: tc.MatchMode) Error!sema.MatchReach {
    return switch (mode) {
        .write => .written,
        .consume => .owned,
        .read => blk: {
            if (self.expect.matching == .nil) break :blk .read;
            const subject = ir.Match.subject(self.expect.matching);
            // A write view the subject makes, a call's or a branch of
            // write views (`match (!a if c else !b)`), is passed on, as
            // `if … as` passes one on (`sema.makesWriteView`).
            if (try sema.makesWriteView(self.ctx, subject)) break :blk .written;
            // A value made here, an enum, an error, an integer, or a
            // Bool, is the match's whole.
            if (ViewCheck.hands(self, subject).kind == .made) if (self.ctx.typeOf(subject)) |ty| switch (self.ctx.types.get(ty)) {
                .nominal, .parameterized_nominal, .imported_nominal, .any_error, .int, .bool, .symbol, .slot => break :blk .read_own,
                else => {},
            };
            // Anything else is read.
            break :blk .read;
        },
    };
}

/// Give a `match` binding `b`, of a field or of the whole subject of
/// type `reached`, its access (`sema.decideBindingAccess`, recorded on
/// its symbol) and the type that access gives it: a write view of what
/// it reaches, or a read view, `!T` read as `?T` and `![]T` as `[]T`,
/// or, with no access, the copy or owner of `reached`. The one place a
/// match binding's mode is decided (docs/internals/INTERNALS.md, "Binding
/// access").
pub fn bindMatchView(self: *Checker, b: Sexp, mode: tc.MatchMode, reached: TypeId) Error!TypeId {
    const access = if (self.isPoison(reached)) null else sema.decideBindingAccess(self.ctx, .{ .match = .{ .reach = try matchReach(self, mode), .reached = reached } });
    const ty = try viewOfAccess(self, access, reached);
    if (self.ctx.symbolOf(b)) |sym| {
        (try self.ctx.symbolMut(sym)).access = access;
        (try self.ctx.symbolMut(sym)).flags.access_decided = true;
        (try self.ctx.symbolMut(sym)).ty = ty;
    }
    return ty;
}

/// The access of the binding of `if … as` or `while … as` of a value
/// of type `inner` reached so (`sema.decideBindingAccess`); none for a
/// poisoned value.
pub fn asAccess(self: *Checker, reach: sema.AsReach, inner: TypeId) ?sema.Access {
    if (self.isPoison(inner)) return null;
    return sema.decideBindingAccess(self.ctx, .{ .as = .{ .reach = reach, .inner = inner } });
}

/// The type a binding with access `access` (`sema.decideBindingAccess`)
/// has, of a value of type `reached`: a write view of it; a read view
/// of it, a write view `!T` read as `?T` and `![]T` as `[]T`; or, with
/// no access, the value, copied or owned. The one place any binding's
/// type is built from its access: a match's, an `as`'s, and a loop's.
pub fn viewOfAccess(self: *Checker, access: ?sema.Access, reached: TypeId) Error!TypeId {
    const a = access orelse return reached;
    return switch (a) {
        .write => switch (self.ctx.types.get(reached)) {
            .write_view => reached,
            else => try self.ctx.intern(.{ .write_view = reached }),
        },
        .read => switch (self.ctx.types.get(reached)) {
            .read_view, .slice, .string_view => reached,
            .write_view => |inner| switch (self.ctx.types.get(inner)) {
                .slice => inner,
                else => try self.ctx.intern(.{ .read_view = inner }),
            },
            else => if (sema.copies(self.ctx, reached) == .no) try self.ctx.intern(.{ .read_view = reached }) else reached,
        },
    };
}

/// The set of variant pattern `pattern`'s member, of a subject of type
/// `subject`, which may be of `several` sets: the set it names
/// (`E.name(...)`), which the subject may be; else the one set of
/// those that has the member; else the subject's. Null once rejected.
pub fn variantPatternSet(self: *Checker, pattern: Sexp, subject: TypeId, several: bool) Error!?TypeId {
    const named = ir.VariantPattern.name(pattern);
    const name = rig.variantPatternName(pattern);
    if (self.isPoison(subject)) return null;
    if (named.isKind(.member)) {
        var r = self.resolver();
        const set = try r.resolveType(ir.Member.object(named));
        if (self.isPoison(set)) return null;
        const shown = try ViewCheck.plainText(self, named);
        if (!sema.isErrorSet(self.ctx, set)) {
            try self.errAt(named, "`{s}` is not a pattern; a qualified pattern names a member of an error set: `E.name`", .{shown});
            return null;
        }
        const within = if (subject == self.t().any_error_id) true else if (sema.isErrorUnion(self.ctx, subject)) sema.errorSubset(self.ctx, set, subject) else set == subject;
        if (!within) {
            try self.errAt(named, "`{s}` is not in `{s}`, the error the subject may be", .{ shown, try self.tyName(subject) });
            return null;
        }
        return set;
    }
    if (!several) return subject;
    const set = if (subject == self.t().any_error_id) try BuiltinCheck.resolveErrorName(self, name) else try BuiltinCheck.unionMemberSet(self, subject, name);
    return if (self.isPoison(set)) null else set;
}

/// The binding of each of `fields`, in field order, that the variant
/// pattern `pattern` writes. A pattern binds a variant's fields by
/// name (`:w`, `w: width`), and a variant with one field also by
/// position (`.circle(r)`); `.nil` stands for a field it leaves out
/// (`sema.SemContext.payloadBindings`). Null after reporting a
/// pattern that does neither.
pub fn fieldBindings(self: *Checker, pattern: Sexp, fields: []const Field) Error!?[]const Sexp {
    const name = rig.variantPatternName(pattern);
    const vname = self.text(name);
    const bindings = ir.VariantPattern.bindings(pattern);
    var named: usize = 0;
    var ok = true;
    for (bindings) |b| {
        if (!b.isKind(.kwarg)) continue;
        named += 1;
        const key = ir.Kwarg.name(b);
        const value = ir.Kwarg.value(b);
        const leaf = if (value.isKind(.some_pattern)) ir.SomePattern.name(value) else value;
        // `:w` is one leaf in both slots.
        if (leaf != .src or leaf.src.pos == key.src.pos) continue;
        const kname = self.text(key);
        if (value == .src and std.mem.eql(u8, self.text(leaf), "_")) {
            try self.errAt(b, "`{s}: _` binds nothing: leave the field out", .{kname});
            ok = false;
        } else if (std.mem.eql(u8, self.text(leaf), kname)) {
            try self.errAt(b, "`{s}` repeats the name: write `:{s}{s}`", .{ CallCheck.sourceText(self, b), kname, if (value.isKind(.some_pattern)) "?" else "" });
            ok = false;
        }
    }
    if (named == 0 and fields.len == 1) {
        if (bindings.len == 1) return bindings;
        try self.err(name.src.pos, "`{s}` has one field: bind it as `{s}(x)`, or by name, `{s}(:{s})`", .{ vname, patternHead(self, pattern), patternHead(self, pattern), fields[0].name });
        return null;
    }
    if (named < bindings.len) {
        try self.err(name.src.pos, "`{s}` has {d} field{s}; bind them by name: `{s}`", .{ vname, fields.len, CompatCheck.plural(fields.len), try byNameText(self, pattern, fields, named == 0 and bindings.len == fields.len) });
        return null;
    }
    if (!ok) return null;
    const binds = try self.ctx.arena.allocator().alloc(Sexp, fields.len);
    @memset(binds, .nil);
    for (bindings) |b| {
        const field = ir.Kwarg.name(b);
        const fname = self.text(field);
        const i = (try sema.findMember(self.ctx, fields, fname, .any)) orelse {
            const likely = ExprCheck.memberSuggest(fields, fname, .field);
            try self.err(field.src.pos, "no field `{s}` on variant `{s}`{s}", .{ fname, vname, try likely.hint(self.ctx.arena.allocator()) });
            ok = false;
            continue;
        };
        if (binds[i] != .nil) {
            try self.err(field.src.pos, "field `{s}` is bound twice", .{fname});
            try self.note(self.startOf(binds[i]), "first bound here", .{});
            ok = false;
            continue;
        }
        binds[i] = ir.Kwarg.value(b);
    }
    return if (ok) binds else null;
}

/// The variant a pattern names, as written: `.rect`, or `E.bad`.
pub fn patternHead(self: *Checker, pattern: Sexp) []const u8 {
    const named = ir.VariantPattern.name(pattern);
    if (named.isKind(.member)) return CallCheck.sourceText(self, named);
    const start = self.startOf(pattern);
    return self.ctx.source[start..self.ctx.span(named).end];
}

/// Variant pattern `pattern` written by name over `fields`: the
/// positional bindings it holds field by field (`.rect(w, _)` is
/// `.rect(:w)`, `.rect(h, w)` is `.rect(w: h, h: w)`) when `mapped`,
/// else each field under its own name.
pub fn byNameText(self: *Checker, pattern: Sexp, fields: []const Field, mapped: bool) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, patternHead(self, pattern));
    var n: usize = 0;
    for (fields, 0..) |f, i| {
        const part = if (!mapped) try a.print(":{s}", .{f.name}) else blk: {
            const b = ir.VariantPattern.bindings(pattern)[i];
            if (b.isKind(.none_pattern)) break :blk try a.print("{s}: none", .{f.name});
            const some = b.isKind(.some_pattern);
            const bound = self.text(if (some) ir.SomePattern.name(b) else b);
            const q = if (some) "?" else "";
            if (std.mem.eql(u8, bound, "_")) {
                if (!some) continue;
                break :blk try a.print("{s}: _?", .{f.name});
            }
            if (std.mem.eql(u8, bound, f.name)) break :blk try a.print(":{s}{s}", .{ f.name, q });
            break :blk try a.print("{s}: {s}{s}", .{ f.name, bound, q });
        };
        try out.appendSlice(a, if (n == 0) "(" else ", ");
        try out.appendSlice(a, part);
        n += 1;
    }
    if (n > 0) try out.append(a, ')');
    return out.items;
}

/// Whether variant pattern `pattern` binds and tests nothing: no
/// field, or `_` for each (`.rect(_, _)`, `.rect(w: _)`, `.dot()`).
pub fn bindsNothing(self: *Checker, pattern: Sexp) bool {
    for (ir.VariantPattern.bindings(pattern)) |b| {
        const v = if (b.isKind(.kwarg)) ir.Kwarg.value(b) else b;
        if (v != .src or !std.mem.eql(u8, self.text(v), "_")) return false;
    }
    return true;
}

pub fn reportMissingVariant(self: *Checker, enum_ty: TypeId, vname: []const u8, pos: u32) Error!void {
    if (sema.unwrapViews(self.ctx, enum_ty) == self.t().symbol_id) {
        return self.err(pos, "`.{s}` is an enum variant, and a `Symbol` is expected; a symbol is written `:{s}`", .{ vname, vname });
    }
    const decl = sema.nominalDecl(self.ctx, enum_ty) orelse {
        if (!self.isPoison(enum_ty)) {
            try self.err(pos, "`.{s}` is an enum variant, but the expected type `{s}` is not an enum", .{ vname, try self.tyName(enum_ty) });
        }
        return;
    };
    const sym = decl.symbol();
    if (sym.fields == null) return;
    try self.err(pos, "no variant `{s}` on enum `{s}`{s}", .{ vname, try self.tyName(sema.unwrapViews(self.ctx, enum_ty)), sema.stdRenamed(decl.ctx, sym.name, vname) orelse "" });
    try noteDeclared(self, sym, decl.module_id == null);
}

/// Point at where type `sym` is declared, when that is in this
/// module's source (`local`), or where the generic type a proxy
/// stands for is.
pub fn noteDeclared(self: *Checker, sym: sema.Symbol, local: bool) Error!void {
    if (sema.isProxy(sym)) {
        const origin = sema.proxyOrigin(self.ctx, sym) orelse return;
        return self.ctx.noteIn(origin.module_id, origin.pos, "`{s}` declared here", .{sym.name});
    }
    if (local and sym.decl_pos < sema.imported_decl_pos) try self.note(sym.decl_pos, "`{s}` declared here", .{sym.name});
}

pub fn synthExpr(self: *Checker, e: Sexp) Error!TypeId {
    const ty = switch (e) {
        .nil => self.t().void_id,
        .src => try ExprCheck.synthLeaf(self, e),
        .str => self.t().static_id,
        .tag => self.t().invalid_id,
        .list => if (e.kind() == null) self.t().invalid_id else try ExprCheck.synthList(self, e),
    };
    if (try cellMadeAway(self, e, ty)) {
        try self.ctx.recordType(e, self.t().invalid_id);
        return self.t().invalid_id;
    }
    try self.ctx.recordType(e, ExprCheck.canonical(self, ty));
    try ExprCheck.noteTakeable(self, e, ty);
    return ty;
}

/// Whether `e`, of type `ty`, makes a value holding a Cell by value
/// where none may stand (`sema.misplaced`): such a value lives only
/// behind a shared handle, so it is made only as the operand of `*`
/// (`shared_operand`), as a field of a value made there, or as a
/// field's default (`cell_home`). A call makes one; so does a value
/// that branches (`sema.yieldsPart`) with a leaf a name holds, which
/// would copy the Cell's holder out of its place while another handle
/// changes the Cell. Such a branch is read only in place
/// (`in_place`: a self, or the operand of a view), or viewed on each
/// branch. True when reported.
pub fn cellMadeAway(self: *Checker, e: Sexp, ty: TypeId) Error!bool {
    if (!e.isKind(.call) and !sema.yieldsPart(e)) return false;
    if (self.isPoison(ty) or !sema.holdsCellByValue(self.ctx, ty)) return false;
    // Typed only to infer a call's type arguments, it stands nowhere
    // yet: it is decided where it is checked.
    if (CompatCheck.sameNode(e, self.expect.shared_operand) or CompatCheck.sameNode(e, self.expect.cell_home) or self.ctx.quiet > 0) return false;
    if (!e.isKind(.call)) return cellCopiedByBranch(self, e, ty);
    const src = CallCheck.sourceText(self, e);
    try self.errAt(e, "`{s}` makes a `{s}`, which holds a Cell, so it lives only behind a shared handle: write `*{s}`", .{ src, try self.tyName(ty), src });
    return true;
}

/// `cellMadeAway` for a branching value `e`: rejected when a leaf is
/// a place (a value a name holds, or a part of one), by a positive
/// list of what may stand there: a value made there, a view, a jump,
/// or a constant.
pub fn cellCopiedByBranch(self: *Checker, e: Sexp, ty: TypeId) Error!bool {
    if (CompatCheck.sameNode(e, self.expect.in_place)) return false;
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, e, &leaves);
    const place = try ViewCheck.heldLeaf(self, leaves.items);
    if (place == .nil) return false;
    const a = self.ctx.arena.allocator();
    const withs = try ViewCheck.viewedLeaves(self, leaves.items, '?');
    const src = CallCheck.sourceText(self, e);
    const multiline = std.mem.findScalar(u8, src, '\n') != null;
    const what = if (multiline) "this value" else try a.print("`{s}`", .{src});
    const fix = if (multiline) "put a `?` before each branch's value" else try a.print("`{s}`", .{try ViewCheck.spliced(self, e, leaves.items, withs)});
    try self.errAt(e, "{s} would copy a `{s}`, which holds a Cell, out of `{s}`, while another handle may change the Cell; put the sigil on each branch: {s}", .{ what, try self.tyName(ty), CallCheck.sourceText(self, place), fix });
    return true;
}
