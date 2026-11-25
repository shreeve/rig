//! Typecheck's expressions: names, literals, operators, equality,
//! numbers, and blocks.

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
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const FunctionType = sema.FunctionType;
const SelfMode = sema.SelfMode;
const NominalContext = sema.NominalContext;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;
const srcPos = sema.srcPos;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const BuiltinCheck = @import("builtins.zig");
const CallCheck = @import("calls.zig");
const ClosureCheck = @import("closures.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StdFormCheck = @import("stdforms.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// An optional field or element that moves, which a diagnostic may
/// offer to take with `<e`: recorded when the take's own check
/// (`requireAccess` of `.take`) would reject it, its diagnostics
/// dropped.
pub fn noteTakeable(self: *Checker, e: Sexp, ty: TypeId) Error!void {
    if (!e.isKind(.member) and !e.isKind(.index)) return;
    if (self.ctx.types.get(ty) != .optional or sema.moves(self.ctx, ty) != .yes) return;
    if (sema.moveSource(self.ctx, e) != .optional_part) return;
    const mark = self.ctx.diagnostics.items.len;
    const place = StmtCheck.placeOf(self, e);
    // A trial: it records nothing a take would, such as a table's
    // slot reached to write.
    const saved = self.trial_take;
    defer self.trial_take = saved;
    self.trial_take = true;
    const ok = place.cell_list_elem == null and try StmtCheck.requireAccess(self, place, .take, e);
    self.ctx.diagnostics.shrinkRetainingCapacity(mark);
    if (!ok) try self.ctx.recordUntakeable(e);
}

/// Literal pseudo-types as the concrete type they default to.
pub fn canonical(self: *Checker, ty: TypeId) TypeId {
    if (ty == self.t().int_literal_id) return self.t().int_id;
    if (ty == self.t().float_literal_id) return self.t().float_id;
    return ty;
}

/// A double-quoted string literal's escapes: `\n`, `\r`, `\t`, `\\`,
/// `\'`, `\"`, `\xNN`, and `\u{N...}`. A single-quoted string takes
/// no escapes.
pub fn checkEscapes(self: *Checker, leaf: Sexp) Error!void {
    const s = self.text(leaf);
    // A template's text takes `\{`, `\}`, and `\``` too.
    const template = rig.isTemplateText(s);
    if (s.len == 0 or (s[0] != '"' and !template)) return;
    const pos = leaf.src.pos;
    var i: usize = 1;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] != '\\') continue;
        const c = s[i + 1];
        const ok = switch (c) {
            'n', 'r', 't', '\\', '\'', '"' => true,
            '{', '}', '`' => template,
            'x' => i + 3 < s.len and std.ascii.isHex(s[i + 2]) and std.ascii.isHex(s[i + 3]),
            'u' => blk: {
                if (i + 2 >= s.len or s[i + 2] != '{') break :blk false;
                var j = i + 3;
                var digits: usize = 0;
                while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) digits += 1;
                if (j >= s.len or s[j] != '}' or digits == 0 or digits > 6) break :blk false;
                const v = std.fmt.parseInt(u32, s[i + 3 .. j], 16) catch break :blk false;
                break :blk v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF);
            },
            else => false,
        };
        if (!ok) {
            if (template) {
                try self.err(pos + @as(u32, @intCast(i)), "invalid escape `\\{c}` in a template; the escapes are `\\n`, `\\r`, `\\t`, `\\\\`, `\\'`, `\\\"`, `\\xNN`, `\\u{{N}}`, `\\{{`, `\\}}`, and `` \\` ``", .{c});
                return;
            }
            try self.err(pos + @as(u32, @intCast(i)), "invalid escape `\\{c}` in a string; the escapes are `\\n`, `\\r`, `\\t`, `\\\\`, `\\'`, `\\\"`, `\\xNN`, and `\\u{{N}}`", .{c});
            return;
        }
        i += 1;
    }
}

pub fn synthLeaf(self: *Checker, leaf: Sexp) Error!TypeId {
    const s = self.text(leaf);
    if (s.len == 0) return self.t().invalid_id;
    if (sema.isStringLiteralText(s)) {
        try checkEscapes(self, leaf);
        return self.t().static_id;
    }
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return self.t().bool_id;
    if (std.mem.eql(u8, s, "none")) return self.t().none_id;
    if (sema.isFloatLiteralText(s)) {
        if (!std.math.isFinite(tc.floatLiteralValue(s))) {
            try self.errAt(leaf, "float literal `{s}` is too large", .{s});
            return self.t().invalid_id;
        }
        return self.t().float_literal_id;
    }
    if (sema.isIntLiteralText(s)) {
        if (std.fmt.parseInt(u128, s, 0)) |_| {} else |_| {
            try self.errAt(leaf, "integer literal `{s}` is too large", .{s});
            return self.t().invalid_id;
        }
        return self.t().int_literal_id;
    }
    const id = (try useName(self, leaf)) orelse return self.t().unknown_id;
    // A task given a write view is only waited for or canceled where
    // it is bound: no use of its name moves it on, a `return` or a last
    // value among them.
    if (self.write_tasks.count() != 0 and !tc.sameSite(leaf, self.task_wait) and self.write_tasks.contains(id)) {
        try self.errAt(leaf, "`{s}` is a task that holds a write view while it runs, so it is only waited for or canceled where it is bound: `>{s}`", .{ s, s });
        return self.t().invalid_id;
    }
    const sym = self.ctx.symbols.items[id];
    switch (sym.kind) {
        .nominal_type, .generic_type, .type_alias, .generic_param => {
            try self.errAt(leaf, "`{s}` is a type, not a value", .{s});
            return self.t().invalid_id;
        },
        .module => {
            try self.errAt(leaf, "`{s}` is a module, not a value; use `{s}.name`", .{ s, s });
            return self.t().invalid_id;
        },
        .@"extern" => if (self.ctx.types.get(sym.ty) == .function) {
            try self.errAt(leaf, "an extern function can only be called, inside `raw`", .{});
            return self.t().invalid_id;
        } else return sym.ty,
        .function => {
            if (isEntryPoint(self, sym)) {
                try self.errAt(leaf, Checker.entry_point_use, .{});
                return self.t().invalid_id;
            }
            if (try optionsValue(self, sym.param_defaults, sym.flags.has_groups, s, leaf.src.pos)) return self.t().invalid_id;
            return functionValue(self, sym.ty, s, leaf.src.pos, sym.flags.inline_marked);
        },
        else => return sym.ty,
    }
}

/// A function with options named as a value, which is refused: a call
/// through a value gives every argument by position, and an option is
/// given by name (SPEC "Functions"). True after the diagnostic.
pub fn optionsValue(self: *Checker, defaults: ?[]const ?Sexp, groups: bool, name: []const u8, pos: u32) Error!bool {
    // A group's fields are options, a default or none.
    if (groups) {
        try self.err(pos, "`{s}` has options, given by name, so it is not a value: write a closure that calls it", .{name});
        return true;
    }
    const d = defaults orelse return false;
    for (d) |x| if (x != null) {
        try self.err(pos, "`{s}` has options, given by name, so it is not a value: write a closure that calls it", .{name});
        return true;
    };
    return false;
}

/// The root module's `main`, which only the program calls.
pub fn isEntryPoint(self: *Checker, sym: sema.Symbol) bool {
    return self.ctx.is_root and sym.kind == .function and sym.scope == sema.module_scope and std.mem.eql(u8, sym.name, "main");
}

/// A function named as a value. One with compile-time parameters has
/// an instance per call, and no single function value; an `inline fun`
/// is inlined at every call, and has no address.
pub fn functionValue(self: *Checker, ty: TypeId, name: []const u8, pos: u32, inline_marked: bool) Error!TypeId {
    if (inline_marked) {
        try self.err(pos, "`{s}` is `inline`, inlined at every call, so it can only be called, not used as a value; to pass it, wrap the call in a closure", .{name});
        return self.t().invalid_id;
    }
    const f = self.ctx.types.get(ty);
    if (f == .function and f.function.ct_params.len != 0) {
        try self.err(pos, "`{s}` takes compile-time parameters, so it can only be called, not used as a value", .{name});
        return self.t().invalid_id;
    }
    return ty;
}

/// Resolve an identifier use, record the fact, and diagnose unbound
/// names and outer locals referenced from inside a closure.
pub fn useName(self: *Checker, leaf: Sexp) Error!?SymbolId {
    if (leaf != .src) return null;
    const name = self.text(leaf);
    if (std.mem.eql(u8, name, "_")) {
        try self.errAt(leaf, Checker.discard_read, .{});
        return null;
    }
    // A read of a group's field the rewrite wrote names the field's
    // parameter, whatever the body declares of its name
    // (`Parser.group_targets`).
    const named = rig.isNamedLeaf(leaf);
    if (named) if (self.ctx.parser) |p| if (p.group_targets.get(leaf.src.pos)) |param| if (self.ctx.symbolOf(param)) |id| {
        try self.ctx.recordName(leaf, id);
        return id;
    };
    // A name the rewrite copied is looked up where its home is.
    const at = if (named) if (self.ctx.parser) |p| p.homeOf(leaf.src.pos) else leaf.src.pos else leaf.src.pos;
    var sid: ?ScopeId = self.scope;
    var crossed_lambda: ?ScopeId = null;
    // A group's fields are no names of the body
    // (docs/design/options.md, section 2): a name the body writes
    // passes them for the scopes around, and is said to be a field's
    // only when nothing else has it.
    var field_of_group: ?SymbolId = null;
    while (sid) |s| {
        if (s == sema.scope_invalid or s >= self.ctx.scopes.items.len) break;
        if (visibleIn(self, s, name, at)) |id| found: {
            if (self.ctx.symbols.items[id].flags.group_field and !named) {
                field_of_group = id;
                break :found;
            }
            try self.ctx.recordName(leaf, id);
            const sym = self.ctx.symbols.items[id];
            const kind = sym.kind;
            if (sym.flags.group) try self.noteGroupUse(leaf, sym);
            // An API is no value; a call names one of its methods,
            // `Shape.area(x)` (`apiNameCall`).
            if (kind == .api) {
                try self.errAt(leaf, "`{s}` is an API, not a value; call a method through it by name: `{s}.method(x)`", .{ name, name });
                return null;
            }
            if (kind == .local and sym.ty == self.t().unknown_id and sym.decl_pos != leaf.src.pos) {
                try self.errAt(leaf, "`{s}` is used before it has a value", .{name});
            }
            if (crossed_lambda != null and s != self.module_scope and (kind == .local or kind == .param or kind == .capture)) {
                if (try ClosureCheck.pastPathCapture(self, leaf, name, crossed_lambda.?)) return id;
                // One error for each closure and local, at its first
                // use: the capture it names fixes every use.
                const key = (@as(u64, crossed_lambda.?) << 32) | id;
                if (self.uncaptured_reported.contains(key)) return id;
                if (self.ctx.quiet == 0) try self.uncaptured_reported.put(self.ctx.arena.allocator(), key, {});
                try self.errAt(leaf, "`{s}` is a local of the enclosing function; capture it to use it inside the closure (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|?{s}|` or `|!{s}|` makes a view of it, `|~{s}|` holds it weakly)", .{ name, name, name, name, name, name });
            }
            return id;
        }
        const scope = self.ctx.scopes.items[s];
        if (scope.kind == .lambda and crossed_lambda == null) crossed_lambda = s;
        sid = scope.parent;
    }
    if (field_of_group) |id| {
        const group = self.ctx.group_fields.get(id) orelse "";
        try self.errAt(leaf, "`{s}` is a field of group `{s}`, not a name of the body: read it as `{s}.{s}`", .{ name, group, group, name });
        return null;
    }
    // A generic type's type parameters are in scope only as types; its
    // value parameters are compile-time values in its methods.
    const type_param = for (self.nominal.type_params) |tp| {
        if (!std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) continue;
        if (self.ctx.symbols.items[tp].kind == .param) {
            try self.ctx.recordName(leaf, tp);
            return tp;
        }
        break true;
    } else false;
    if (type_param or resolve.isBuiltinTypeName(self.ctx, name)) {
        try self.errAt(leaf, "`{s}` is a type, not a value", .{name});
        return null;
    }
    if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "warn")) {
        try self.errAt(leaf, "`{s}` is called with parentheses: `{s}(...)`", .{ name, name });
        return null;
    }
    // Inside a type's methods, a field or method is reached through
    // self.
    if (!self.nominal.isEmpty()) {
        const has_self = CallCheck.lookupAt(self, self.scope, "@", leaf.src.pos) != null;
        const method = self.body.name;
        if (std.mem.eql(u8, name, "@") and method != .nil) {
            try self.errAt(leaf, "`{s}` takes no self: write `{s} {s}(?@)`, `(!@)`, or `(<@)`", .{ self.text(method), if (self.body.is_sub) "sub" else "fun", self.text(method) });
            return null;
        }
        if (self.ctx.symbols.items[self.nominal.sym].fields) |members| for (members) |m| {
            if (m.is_variant or !std.mem.eql(u8, m.name, name)) continue;
            const call: []const u8 = if (m.is_method) "(...)" else "";
            if (has_self) {
                try self.errAt(leaf, "use of unbound name `{s}`; did you mean `@{s}{s}`?", .{ name, name, call });
            } else try self.errAt(leaf, "use of unbound name `{s}`; `{s}` is a member of `{s}`, reached through self: declare `(?@)` and write `@{s}{s}`", .{ name, name, self.ctx.symbols.items[self.nominal.sym].name, name, call });
            return null;
        };
    }
    try self.errAt(leaf, "use of unbound name `{s}`{s}", .{ name, try unboundHint(self, leaf, name) });
    return null;
}

/// The member of `members` a name not found among them is a typo
/// of: a data field, a method, or (called through the type) a
/// method or variant.
pub fn memberHint(self: *Checker, members: []const Field, name: []const u8, want: Checker.MemberKind) Error![]const u8 {
    return memberSuggest(members, name, want).hint(self.ctx.arena.allocator());
}

pub fn memberSuggest(members: []const Field, name: []const u8, want: Checker.MemberKind) sema.Suggest {
    var s: sema.Suggest = .{ .name = name };
    for (members) |m| {
        if (m.is_drop_method) continue;
        const ok = switch (want) {
            .field => !m.is_method and !m.is_variant,
            .method => m.is_method,
            .associated => m.is_method or m.is_variant,
        };
        if (ok) s.offer(m.name);
    }
    return s;
}

/// What a name not found here was likely meant as: another
/// language's spelling of a Rig one, or a visible name it is a typo
/// of.
pub fn unboundHint(self: *Checker, leaf: Sexp, name: []const u8) Error![]const u8 {
    if (sema.builtinNameHint(name)) |hint| return hint;
    const other = try self.ctx.otherFileUse(name);
    if (other.len > 0) return other;
    const Other = struct { []const u8, []const u8 };
    const others = [_]Other{
        .{ "null", "; Rig's absent value is `none`" },
        .{ "nil", "; Rig's absent value is `none`" },
        .{ "None", "; Rig's absent value is `none`" },
        .{ "NULL", "; Rig's absent value is `none`" },
        .{ "True", "; Rig writes `true`" },
        .{ "False", "; Rig writes `false`" },
        .{ "this", "; a method's self is `@`, declared as `(?@)`, `(!@)`, or `(<@)`" },
        .{ "@", "; `@` is the self of a method that declares it: `(?@)`, `(!@)`, or `(<@)`" },
        .{ "len", "; a length is a member: `x.len`" },
        .{ "println", "; Rig prints a line with `print(...)`" },
        .{ "puts", "; Rig prints a line with `print(...)`" },
        .{ "printf", "; Rig prints a line with `print(...)`" },
        .{ "range", "; Rig writes a range `0..3`, or `a..b` for `range(a, b)`" },
        .{ "enumerate", "; write `for x, i in xs`: the element first, then its index" },
    };
    for (others) |o| if (std.mem.eql(u8, name, o[0])) return o[1];
    for (self.else_conds.items) |c| if (try FlowCheck.conditionBinds(self, c, name)) {
        return self.ctx.arena.allocator().print("; the condition binds `{s}` only for what runs when it holds, not for `else`", .{name});
    };
    var s: sema.Suggest = .{ .name = name };
    self.ctx.offerVisible(&s, self.scope, leaf.src.pos, struct {
        fn keep(sym: sema.Symbol) bool {
            return sym.decl_pos != sema.builtin_decl_pos or sym.kind != .local;
        }
    }.keep);
    for ([_][]const u8{ "true", "false", "print" }) |w| s.offer(w);
    return s.hint(self.ctx.arena.allocator());
}

/// The binding `name` denotes at `pos` among those declared directly
/// in `scope`: the latest one whose declaration comes before `pos`,
/// excluding a `new x = ...` whose value is still being checked (its
/// right side reads the previous `x`).
pub fn visibleIn(self: *Checker, scope: ScopeId, name: []const u8, pos: u32) ?SymbolId {
    // A module is named where a `use` of its file binds it.
    if (scope == self.module_scope) if (self.ctx.fileModule(name, pos)) |id| return id;
    var id = self.ctx.lookupInScopeOnly(scope, name) orelse return null;
    while (id != sema.symbol_invalid) {
        const sym = self.ctx.symbols.items[id];
        // A module-level constant is visible in every function body,
        // and in every constant (`SemContext.const_order`).
        const later = scope != self.module_scope and sym.declaredAfter(pos);
        if (sym.kind == .local and (later or id == self.pending or std.mem.findScalar(SymbolId, self.pending_names, id) != null)) {
            id = sym.prev_in_scope;
            continue;
        }
        return id;
    }
    return null;
}

pub fn synthList(self: *Checker, e: Sexp) Error!TypeId {
    const head = e.kind().?;
    return switch (head) {
        .call => CallCheck.synthCall(self, e),
        .member => ViewCheck.synthMember(self, e),
        .index, .inst => CallCheck.synthIndex(self, e),
        .ct_call => CallCheck.synthCtCall(self, e),
        .propagate => synthPropagate(self, e),
        .propagate_none => synthPropagateNone(self, e),
        .@"if" => FlowCheck.checkIfValue(self, e, null, .value),
        .match => PatternCheck.checkMatch(self, e, .value, null),
        .block => synthBlock(self, e, null),
        .raw_block => blk: {
            self.raw_depth += 1;
            defer self.raw_depth -= 1;
            break :blk PatternCheck.synthExpr(self, ir.RawBlock.body(e));
        },
        .read => synthView(self, e, .read),
        .write => synthView(self, e, .write),
        .move => ViewCheck.synthMove(self, e),
        .share => ViewCheck.synthShare(self, e),
        .box => ViewCheck.synthBox(self, e, null),
        .weak => ViewCheck.synthWeak(self, e),
        .clone => ViewCheck.synthClone(self, e),
        .@"+", .@"-", .@"*", .@"/", .@"%" => checkNumericOperands(self, e, @tagName(head), .numeric, null),
        .@"&", .@"|", .@"^", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|" => checkNumericOperands(self, e, @tagName(head), .integer, null),
        .@"<<", .@"<<%", .@">>" => synthShift(self, e, @tagName(head)),
        .@"<", .@">", .@"<=", .@">=" => synthOrdering(self, e, @tagName(head)),
        .@"==", .@"!=" => synthEquality(self, e),
        .@"and", .@"or" => blk: {
            const saved_op = self.logic_op;
            const saved_operands = self.logic_operands;
            defer {
                self.logic_op = saved_op;
                self.logic_operands = saved_operands;
            }
            self.logic_op = @tagName(head);
            self.logic_operands = .{ ir.get(e, .left), ir.get(e, .right) };
            try ViewCheck.checkExpr(self, ir.get(e, .left), self.t().bool_id);
            try ViewCheck.checkExpr(self, ir.get(e, .right), self.t().bool_id);
            break :blk self.t().bool_id;
        },
        .not => blk: {
            const saved_not = self.not_operand;
            defer self.not_operand = saved_not;
            self.not_operand = ir.Not.operand(e);
            try ViewCheck.checkExpr(self, ir.Not.operand(e), self.t().bool_id);
            try checkNotScope(self, e);
            break :blk self.t().bool_id;
        },
        .neg => synthNeg(self, e),
        .@"??" => synthCoalesce(self, e, null),
        .@"catch" => synthCatch(self, e, null),
        .array => CallCheck.synthArray(self, e),
        .array_fill => CallCheck.checkArrayFill(self, e, null),
        .enum_lit => blk: {
            const name = self.text(ir.EnumLit.name(e));
            try self.errAt(e, "enum literal `.{s}` needs a known enum type; write `Type.{s}` or annotate the binding", .{ name, name });
            break :blk self.t().invalid_id;
        },
        .symbol => self.t().symbol_id,
        .lambda => ClosureCheck.checkLambda(self, e, null),
        .builtin => BuiltinCheck.synthBuiltin(self, e, null),
        .@"..",
        => blk: {
            try self.errAt(e, "a range `a..b` can only be used as a `for` loop source", .{});
            break :blk self.t().invalid_id;
        },
        .@"while", .@"for", .labeled, .set, .destructure, .drop, .@"defer", .@"errdefer" => if (FlowCheck.isValueLoop(self, e)) FlowCheck.checkLoopValue(self, e, null, true) else if (try FlowCheck.noLoopValue(self, e, null)) |ty| ty else blk: {
            try StmtCheck.checkStmt(self, e);
            break :blk self.t().void_id;
        },
        .pass => blk: {
            try self.errAt(e, "`pass` does nothing and has no value, and a value is needed here", .{});
            break :blk self.t().invalid_id;
        },
        .rarely => blk: {
            try self.errAt(e, "`rarely` marks the block it starts and has no value, and a value is needed here", .{});
            break :blk self.t().invalid_id;
        },
        .@"return" => blk: {
            try StmtCheck.checkReturn(self, e);
            break :blk self.t().noreturn_id;
        },
        .@"break", .@"continue" => blk: {
            try StmtCheck.checkStmt(self, e);
            break :blk self.t().noreturn_id;
        },
        .panic => StdFormCheck.checkPanic(self, e),
        .as => blk: {
            try self.errAt(e, "`as` binds only in the condition of an `if` or `while` block or of a ternary, alone or joined to the rest by `and`", .{});
            _ = try PatternCheck.synthExpr(self, ir.As.value(e));
            break :blk self.t().invalid_id;
        },
        .as_match => blk: {
            try self.errAt(e, "`as` binds only in the condition of an `if` or `while` block or of a ternary, alone or joined to the rest by `and`", .{});
            _ = try FlowCheck.synthQuiet(self, ir.Match.subject(rig.asMatchOf(e)));
            break :blk self.t().invalid_id;
        },
        .as_results => blk: {
            try self.errAt(e, "`as` binds only in the condition of an `if` or `while` block or of a ternary, alone or joined to the rest by `and`", .{});
            _ = try FlowCheck.synthQuiet(self, ir.AsResults.value(e));
            for (ir.AsResults.names(e).items()) |n| if (n.isKind(.set)) try StmtCheck.poisonTarget(self, n);
            break :blk self.t().invalid_id;
        },
        .kwarg => blk: {
            try self.errAt(e, "`name: value` is only allowed as a call argument", .{});
            break :blk self.t().invalid_id;
        },
        .spread => blk: {
            _ = try FlowCheck.synthQuiet(self, ir.Spread.value(e));
            try self.errAt(e, "a spread gives a stored value's fields to a group of a function, `fetch(url, ..net)`, or to the object it updates, `Point(x: 3, ..p)`", .{});
            break :blk self.t().invalid_id;
        },
        // A destructure's target takes the result in its position.
        .result_part => self.part_ty,
        .tuple => StmtCheck.tupleValue(self, e),
        .template => StdFormCheck.synthTemplate(self, e),
        else => blk: {
            try self.errAt(e, "`{s}` expressions are not supported", .{@tagName(head)});
            break :blk self.t().invalid_id;
        },
    };
}

/// The operands of binary operator `(op left right)`: both numeric
/// (or integer) and of one type. Literals adapt to the other operand;
/// generic parameters record a requirement. `synthesized` holds the
/// operands' types when the caller has synthesized them.
pub fn checkNumericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
    const ty = try numericOperands(self, e, op, req, synthesized);
    if (self.isPoison(ty)) return ty;
    if (!(try checkDivisor(self, e.kind().?, ty, ir.get(e, .right)))) return self.t().invalid_id;
    try checkConstantFits(self, e, ty);
    // Literals default to `Float` unless a type is given them later.
    if (ty == self.t().float_literal_id) {
        try ViewCheck.checkWholeDivision(self, e);
        try ViewCheck.checkFloatConstant(self, e, self.t().float_id);
    } else if (self.ctx.types.get(ty) == .float) try ViewCheck.checkFloatConstant(self, e, ty);
    return ty;
}

/// Constant operands are computed now, so an integer result must fit.
/// (The constant parts of an operation that is not constant were
/// checked as operands.)
pub fn checkConstantFits(self: *Checker, e: Sexp, ty: TypeId) Error!void {
    if (self.ctx.types.get(ty) != .int or sema.constInt(self.ctx, e) == .not_constant) return;
    try BuiltinCheck.checkLiteralFits(self, e, ty);
}

/// `checkNumericOperands` where two literal operands, which take no
/// type from each other, are `Int`s.
pub fn checkIntDefaultOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
    const ty = try checkNumericOperands(self, e, op, req, synthesized);
    if (ty != self.t().int_literal_id) return ty;
    try ViewCheck.defaultIntLiteral(self, ir.get(e, .left));
    try ViewCheck.defaultIntLiteral(self, ir.get(e, .right));
    return self.t().int_id;
}

/// `a < b`, `<=`, `>`, `>=`: two numbers as for arithmetic, two
/// values of one plain enum, by their variants' values, or two
/// Strings or two `[]U8` slices, ordered by their bytes.
pub fn synthOrdering(self: *Checker, e: Sexp, op: []const u8) Error!TypeId {
    const l = ir.get(e, .left);
    const r = ir.get(e, .right);
    // A `.variant` takes its enum type from the other side, as beside
    // `==`.
    if (l.isKind(.enum_lit) != r.isKind(.enum_lit)) {
        const lit, const other = if (l.isKind(.enum_lit)) .{ l, r } else .{ r, l };
        const ty = try ViewCheck.synthReached(self, other);
        if (self.isPoison(ty)) return self.t().bool_id;
        const mark = self.ctx.diagnostics.items.len;
        try ViewCheck.checkExpr(self, lit, ty);
        if (self.ctx.diagnostics.items.len == mark) try checkOrderedEnum(self, l, ty, op);
        return self.t().bool_id;
    }
    const saved = self.beside;
    self.beside = .{ .node = l, .other = r };
    const a = try ViewCheck.synthReached(self, l);
    self.beside = .{ .node = r, .other = l, .ty = a };
    const b = try ViewCheck.synthReached(self, r);
    self.beside = saved;
    if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
    if (try ViewCheck.byteBeside(self, .{ l, r }, a, b) != null) return self.t().bool_id;
    if (try literalBesideSlot(self, l, r, a, b)) return self.t().bool_id;
    if (sema.unwrapViews(self.ctx, a) == self.t().symbol_id or sema.unwrapViews(self.ctx, b) == self.t().symbol_id) {
        try self.errAt(l, "operator `{s}` is not defined for `Symbol`: a symbol has no order; compare with `==` and `!=`", .{op});
        return self.t().bool_id;
    }
    // Two values of one type that provides `Ord` beside the numbers
    // and text: `Bool`, a String, an optional, an array, or a slice of
    // ordered values, and an object or an enum whose header names `Ord`.
    // A type parameter's instances or bounds order it, and its value
    // may own a resource too.
    const ordered = try orderedBeside(self, a, b);
    if (ordered or sema.containsTypeVar(self.ctx, a) or sema.containsTypeVar(self.ctx, b)) {
        // An operand whose value may move is read where it is, and a
        // temporary of it is dropped with its statement, as beside `==`.
        for ([2]Sexp{ l, r }) |operand| {
            const own = self.ctx.typeOf(operand) orelse continue;
            if (!self.isPoison(own) and sema.moves(self.ctx, own) != .no) try ViewCheck.readLeaf(self, operand);
        }
        if (ordered) return self.t().bool_id;
    }
    if (CallCheck.enumValues(self, a) != null or CallCheck.enumValues(self, b) != null) {
        if (a != b) {
            try self.errAt(l, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
        } else try checkOrderedEnum(self, l, a, op);
        return self.t().bool_id;
    }
    // Lane by lane: a mask.
    if (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null) {
        const vt = try StdFormCheck.simdOperands(self, e, op, .ordered, a, b);
        return if (self.isPoison(vt)) vt else StdFormCheck.maskOf(self, self.ctx.types.get(vt).simd);
    }
    if (!isBytes(self, a) and !isBytes(self, b)) {
        _ = try checkIntDefaultOperands(self, e, op, .ordered, .{ a, b });
        return self.t().bool_id;
    }
    // Ordering reads both texts: a `Static` beside a `?String`.
    const a_read = if (a == self.t().static_id) self.t().string_view_id else a;
    const b_read = if (b == self.t().static_id) self.t().string_view_id else b;
    if (a_read != b_read) try self.errAt(l, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
    return self.t().bool_id;
}

/// An integer literal beside a slot in a comparison, `s == 0` or
/// `s < 3`: it is a `Slot[n]` there, as where one is expected, and
/// checked to fit below `n` (`checkExpr`, as a literal beside a number
/// is in `checkNumericComparison`). True when one side was such a
/// literal.
pub fn literalBesideSlot(self: *Checker, l: Sexp, r: Sexp, a: TypeId, b: TypeId) Error!bool {
    const lit = self.t().int_literal_id;
    const slot_l = self.ctx.types.get(sema.unwrapViews(self.ctx, a)) == .slot;
    const slot_r = self.ctx.types.get(sema.unwrapViews(self.ctx, b)) == .slot;
    if (a == lit and slot_r) {
        try ViewCheck.checkExpr(self, l, sema.unwrapViews(self.ctx, b));
        return true;
    }
    if (b == lit and slot_l) {
        try ViewCheck.checkExpr(self, r, sema.unwrapViews(self.ctx, a));
        return true;
    }
    return false;
}

/// Whether `a` and `b`, an ordering's operands, are one type that
/// provides `Ord` (`sema.lacks`) and is ordered by `rig.compare`: not a
/// number, `?String`, `Static`, or byte slice, which their own paths
/// order, nor a type parameter, whose bounds or instances do.
pub fn orderedBeside(self: *Checker, a: TypeId, b: TypeId) Error!bool {
    const ra = sema.unwrapViews(self.ctx, a);
    if (ra != sema.unwrapViews(self.ctx, b)) return false;
    if (sema.isNumeric(self.ctx, ra) or isBytes(self, ra) or sema.containsTypeVar(self.ctx, ra)) return false;
    switch (self.ctx.types.get(ra)) {
        .string_view, .static => return false,
        else => {},
    }
    if (sema.isOrderedEnum(self.ctx, ra)) return false;
    return (try sema.lacks(self.ctx, ra, .Ord)) == null;
}

/// Two values of type `ty` ordered by operator `op`, at `at`, where
/// one is an enum's: a plain enum orders by its variants' values.
pub fn checkOrderedEnum(self: *Checker, at: Sexp, ty: TypeId, op: []const u8) Error!void {
    if (sema.isOrderedEnum(self.ctx, ty)) return;
    const builtin = switch (self.ctx.types.get(ty)) {
        .nominal => |sym| sema.isBuiltinEnum(self.ctx, sym),
        else => false,
    };
    if (builtin) {
        try self.errAt(at, "operator `{s}` orders a declared enum's values; the built-in enum `{s}` has no integer value", .{ op, try self.tyName(ty) });
    } else if (self.ctx.types.get(ty) == .parameterized_nominal) {
        try self.errAt(at, "operator `{s}` orders a plain enum's values; `{s}` is a generic enum, whose variants have no integer value", .{ op, try self.tyName(ty) });
    } else if (CallCheck.enumValues(self, ty) == false) {
        try self.errAt(at, "operator `{s}` orders a plain enum's values; `{s}` has variants with payloads, which have no integer value; name `Ord` on its header to order it by variant, then payload: `enum {s}: Ord`", .{ op, try self.tyName(ty), try self.tyName(ty) });
    } else try orderingOperand(self, at, op, ty);
}

/// `l` of type `a` and `r` of type `b`, which `==` cannot compare;
/// a number beside a `Duration` is no duration (`sema.duration`).
pub fn cannotCompare(self: *Checker, l: Sexp, r: Sexp, a: TypeId, b: TypeId) Error!void {
    const dl = sema.isDurationType(self.ctx, sema.unwrapViews(self.ctx, a)) and sema.isNumeric(self.ctx, b);
    const dr = sema.isDurationType(self.ctx, sema.unwrapViews(self.ctx, b)) and sema.isNumeric(self.ctx, a);
    if (dl or dr) return self.errAt(l, "cannot compare `{s}` with `{s}`: a number is no duration, so write `time.duration({s})`", .{ try self.tyName(a), try self.tyName(b), CallCheck.sourceText(self, if (dl) r else l) });
    try self.errAt(l, "cannot compare `{s}` with `{s}`", .{ try self.tyName(a), try self.tyName(b) });
}

/// An operand of an ordering at `at`, of type `ty`, that provides no
/// `Ord`.
pub fn orderingOperand(self: *Checker, at: Sexp, op: []const u8, ty: TypeId) Error!void {
    const lack: sema.Lack = (try sema.lacks(self.ctx, ty, .Ord)) orelse .{ .ty = ty };
    try self.errAt(at, "operator `{s}` orders values of one type that provides `Ord`, and `{s}` cannot be ordered{s}", .{ op, try self.tyName(ty), try sema.lackDetail(self.ctx, self.ctx.arena.allocator(), ty, .Ord, lack) });
}

/// `not` applies to the whole comparison after it: `not a > b` is
/// `not (a > b)`, which reads as `(not a) > b` too. So a comparison
/// directly under `not` is written in parentheses, or flipped where
/// the flip means the same: `a <= b` for integers and text, `a != b`
/// for any `==`. (`not (a > b)` is not `a <= b` for a Float NaN.)
pub fn checkNotScope(self: *Checker, e: Sexp) Error!void {
    const operand = ir.Not.operand(e);
    const op: []const u8, const flipped: []const u8 = switch (operand.kind() orelse return) {
        .@"==" => .{ "==", "!=" },
        .@"!=" => .{ "!=", "==" },
        .@"<" => .{ "<", ">=" },
        .@">" => .{ ">", "<=" },
        .@"<=" => .{ "<=", ">" },
        .@">=" => .{ ">=", "<" },
        else => return,
    };
    const whole = self.ctx.span(e);
    const cmp = self.ctx.span(operand);
    // Written in parentheses: `not` ends past its operand, at `)`.
    if (whole.end > cmp.end) return;
    const a = self.ctx.arena.allocator();
    const shown = try tc.oneLine(self.ctx.arena.allocator(), try tc.withoutComments(self.ctx.arena.allocator(), CallCheck.sourceText(self, operand)));
    const equality = op[0] == '=' or op[0] == '!';
    const exact = equality or (flipsExactly(self, ir.get(operand, .left)) and flipsExactly(self, ir.get(operand, .right)));
    // The operator, between the two sides' spans (and any
    // parentheses around them).
    const gap_start = self.ctx.span(ir.get(operand, .left)).end;
    const gap_end = self.ctx.span(ir.get(operand, .right)).start;
    const at = if (exact and gap_start <= gap_end) std.mem.find(u8, diag.textBetween(self.ctx.source, gap_start, gap_end), op) else null;
    if (at) |i| {
        const o = gap_start + i;
        const flip = try tc.oneLine(a, try tc.withoutComments(a, try std.mem.concat(a, u8, &.{ diag.textBetween(self.ctx.source, cmp.start, o), flipped, diag.textBetween(self.ctx.source, o + op.len, cmp.end) })));
        return self.errAt(e, "write `{s}`, or `not ({s})`: `not` applies to the whole comparison", .{ flip, shown });
    }
    try self.errAt(e, "write `not ({s})`: `not` applies to the whole comparison", .{shown});
}

/// Whether a side of an ordering keeps its meaning when the ordering
/// is flipped (`not (a > b)` is `a <= b`): an integer, a plain enum,
/// or text, which are totally ordered, unlike a Float.
pub fn flipsExactly(self: *Checker, side: Sexp) bool {
    const ty = self.ctx.typeOf(side) orelse return false;
    const v = sema.unwrapViews(self.ctx, ty);
    return sema.isInteger(self.ctx, v) or isBytes(self, v) or sema.isOrderedEnum(self.ctx, v);
}

/// A `?String` or a `[]U8`: bytes ordered as text is.
pub fn isBytes(self: *Checker, ty: TypeId) bool {
    return switch (self.ctx.types.get(ty)) {
        .string_view, .static => true,
        .slice => |s| switch (self.ctx.types.get(s.elem)) {
            .int => |info| info.bits == 8 and !info.signed,
            else => false,
        },
        else => false,
    };
}

/// Integer division by a constant zero is rejected; float division
/// gives an infinity or NaN.
pub fn checkDivisor(self: *Checker, op: Tag, ty: TypeId, divisor: Sexp) Error!bool {
    if (op != .@"/" and op != .@"%") return true;
    switch (self.ctx.types.get(ty)) {
        .float, .float_literal => return true,
        else => {},
    }
    if ((constInt(self, divisor) orelse return true) != 0) return true;
    try self.errAt(divisor, "division by zero", .{});
    return false;
}

/// `a << n` / `a >> n`: the result has the type of the integer `a`.
pub fn synthShift(self: *Checker, e: Sexp, op: []const u8) Error!TypeId {
    const left = ir.get(e, .left);
    const ty = try ViewCheck.synthOperandValue(self, left);
    if (self.isPoison(ty)) {
        _ = try PatternCheck.synthExpr(self, ir.get(e, .right));
        return ty;
    }
    // A vector of integers shifts each lane by one amount, with the
    // rules of its lane type.
    if (sema.simdOf(self.ctx, ty)) |v| {
        if (!sema.isInteger(self.ctx, v.elem)) {
            try self.errAt(left, "operator `{s}` requires integer lanes; got `{s}`", .{ op, try self.tyName(sema.unwrapViews(self.ctx, ty)) });
            _ = try PatternCheck.synthExpr(self, ir.get(e, .right));
            return self.t().invalid_id;
        }
        if (!(try checkShiftAmount(self, ir.get(e, .right), v.elem, op))) return self.t().invalid_id;
        return sema.unwrapViews(self.ctx, ty);
    }
    switch (self.ctx.types.get(ty)) {
        .type_var => |tv| try require(self, tv, .integer, self.startOf(left), op),
        else => if (!sema.isInteger(self.ctx, ty)) {
            try self.errAt(left, "operator `{s}` requires integer operands; got `{s}`", .{ op, try self.tyName(ty) });
            _ = try PatternCheck.synthExpr(self, ir.get(e, .right));
            return self.t().invalid_id;
        },
    }
    if (!(try checkShiftAmount(self, ir.get(e, .right), ty, op))) return self.t().invalid_id;
    try checkConstantFits(self, e, ty);
    return ty;
}

/// A shift amount may be any integer; a constant one must be below
/// the width of the shifted type. A literal's is checked when it
/// takes its type (`recordLiteralType`).
pub fn checkShiftAmount(self: *Checker, amount: Sexp, shifted: TypeId, op: []const u8) Error!bool {
    const ty = try ViewCheck.synthOperandValue(self, amount);
    if (self.isPoison(ty)) return false;
    switch (self.ctx.types.get(ty)) {
        .type_var => |tv| try require(self, tv, .integer, self.startOf(amount), op),
        else => if (!sema.isInteger(self.ctx, ty)) {
            const each = if (sema.simdOf(self.ctx, ty) != null) "; a vector's lanes all shift by one integer" else "";
            try self.errAt(amount, "a shift amount must be an integer; got `{s}`{s}", .{ try self.tyName(ty), each });
            return false;
        },
    }
    const v = constInt(self, amount) orelse return true;
    const width: ?Wide = switch (self.ctx.types.get(shifted)) {
        .int => |info| tc.intBounds(info).bits,
        .type_var => |tv| blk: {
            if (v >= 0) try require(self, tv, .{ .shift = v }, self.startOf(amount), op);
            break :blk null;
        },
        else => null,
    };
    if (v >= 0 and (width == null or v < width.?)) return true;
    if (width) |w| {
        try self.errAt(amount, "shift amount `{d}` is out of range for `{s}` (0..{d})", .{ v, try self.tyName(canonical(self, shifted)), w - 1 });
    } else try self.errAt(amount, "shift amount `{d}` is negative", .{v});
    return false;
}

pub fn constInt(self: *Checker, e: Sexp) ?Wide {
    return sema.constIntOf(self.ctx, e);
}

pub fn numericOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, synthesized: ?[2]TypeId) Error!TypeId {
    const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
    const saved = self.beside;
    self.beside = .{ .node = operands[0], .other = operands[1] };
    const a = if (synthesized) |ts| ts[0] else try ViewCheck.synthOperandValue(self, operands[0]);
    self.beside = .{ .node = operands[1], .other = operands[0], .ty = a };
    const b = if (synthesized) |ts| ts[1] else try ViewCheck.synthOperandValue(self, operands[1]);
    self.beside = saved;
    const pos = self.startOf(operands[0]);
    if (self.isPoison(a) or self.isPoison(b)) return self.t().invalid_id;
    if (try ViewCheck.byteBeside(self, operands, a, b)) |ty| return ty;
    if (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null) return StdFormCheck.simdOperands(self, e, op, req, a, b);

    const ta = self.ctx.types.get(a);
    const tb = self.ctx.types.get(b);
    if (ta == .type_var or tb == .type_var) {
        const tv = if (ta == .type_var) a else b;
        const other = if (ta == .type_var) b else a;
        if (!meetsTypeVar(self, tv, other, req)) {
            try self.err(pos, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
            return self.t().invalid_id;
        }
        const param = self.ctx.types.get(tv).type_var;
        try require(self, param, req, pos, op);
        try requireHoldsLiteral(self, param, other, if (ta == .type_var) operands[1] else operands[0], pos, op);
        return tv;
    }

    const want_int = req == .integer;
    for ([_]TypeId{ a, b }, 0..) |ty, i| {
        const ok = if (want_int) sema.isInteger(self.ctx, ty) else sema.isNumeric(self.ctx, ty);
        if (!ok) {
            if (req == .ordered) {
                // An optional orders beside another (`orderedBeside`).
                if (self.ctx.types.get(ty) == .optional and self.ctx.types.get(if (i == 0) b else a) != .optional) {
                    const shown = CallCheck.sourceText(self, operands[i]);
                    try self.errAt(operands[i], "operator `{s}` orders an optional only beside another, and `{s}` is {s} `{s}` beside {s} `{s}`: give it a value, `{s} ?? x`, or test it, `if {s} as v`", .{ op, shown, tc.article(try self.tyName(ty)), try self.tyName(ty), tc.article(try self.tyName(if (i == 0) b else a)), try self.tyName(if (i == 0) b else a), shown, shown });
                } else if ((try sema.lacks(self.ctx, ty, .Ord)) == null) {
                    // It is ordered; the other operand is another type.
                    const other = if (i == 0) b else a;
                    const shown = CallCheck.sourceText(self, operands[1 - i]);
                    const fix = if (sema.isDurationType(self.ctx, sema.unwrapViews(self.ctx, ty)) and sema.isNumeric(self.ctx, other)) try std.fmt.allocPrint(self.ctx.arena.allocator(), ": a number is no duration, so write `time.duration({s})`", .{shown}) else "";
                    try self.errAt(operands[1 - i], "operator `{s}` orders two values of one type, and `{s}` is {s} `{s}` beside {s} `{s}`{s}", .{ op, shown, tc.article(try self.tyName(other)), try self.tyName(other), tc.article(try self.tyName(ty)), try self.tyName(ty), fix });
                } else try orderingOperand(self, operands[i], op, ty);
            } else {
                // String is built, not added: `String(a, b)`, `!t.add(b)`.
                const is_text = ty == self.t().string_view_id or ty == self.t().static_id or ty == self.t().string_id;
                const hint = if (is_text and std.mem.eql(u8, op, "+")) "; Rig has no `+` on text: build it with `String(a, b)` or `!t.add(...)`" else "";
                try self.errAt(operands[i], "operator `{s}` requires {s} operands; got `{s}`{s}", .{ op, if (want_int) "integer" else "numeric", try self.tyName(ty), hint });
            }
            return self.t().invalid_id;
        }
    }
    const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
    const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
    if (a_lit and b_lit) {
        if (a == self.t().int_literal_id and b == self.t().int_literal_id) return a;
        // The integer literals become floats.
        for ([_]TypeId{ a, b }, operands) |ty, o| if (ty == self.t().int_literal_id) if (ViewCheck.integerOnlyOp(o)) |int_op| {
            try self.errAt(int_op, "operator `{s}` is for integers, and its literal operands here take the type `Float`", .{@tagName(int_op.kind().?)});
            return self.t().invalid_id;
        };
        return self.t().float_literal_id;
    }
    if (a_lit) {
        try ViewCheck.checkExpr(self, operands[0], b);
        return b;
    }
    if (b_lit) {
        try ViewCheck.checkExpr(self, operands[1], a);
        return a;
    }
    if (a != b) {
        try self.err(pos, "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
        return self.t().invalid_id;
    }
    return a;
}

/// Whether `other` meets generic `tv` in an operator: as another `tv`,
/// or as a literal, which becomes a `tv` (a float literal only where
/// `req` allows a float).
pub fn meetsTypeVar(self: *Checker, tv: TypeId, other: TypeId, req: Requirement) bool {
    return other == tv or other == self.t().int_literal_id or (req != .integer and other == self.t().float_literal_id);
}

pub fn require(self: *Checker, param: SymbolId, req: Requirement, pos: u32, op: []const u8) Error!void {
    if (try decidedByOwnerBounds(self, param, req, pos)) return;
    var r: sema.GenericRequirement = .{ .param = param, .req = req, .pos = pos, .op = op };
    // What a method's body gives a task, or hides from the rules that
    // wait for one, is checked where the method is reached.
    if (req == .task or req == .no_task) if (bodyParam(self, param)) |index| {
        r.body = self.body_pos;
        r.index = index;
    };
    try self.ctx.generic_requirements.append(self.ctx.allocator, r);
}

/// `param`'s place among the parameters the reach of the method being
/// checked binds (`sema.BodyReach`): an API default's `Self`, or the
/// type's or the addition's own; null for another.
pub fn bodyParam(self: *Checker, param: SymbolId) ?u32 {
    if (self.body_pos == sema.no_body) return null;
    switch (self.ctx.types.get(self.nominal.self_type)) {
        .type_var => |s| return if (s == param) 0 else null,
        else => {},
    }
    const i = std.mem.findScalar(SymbolId, self.nominal.type_params, param) orelse return null;
    return @intCast(i);
}

/// Whether the method of the type being checked declared at `pos` is
/// called without a call written: a `drop`, or one that gives a
/// built-in API its meaning (`sema.ownApiMethod`).
pub fn calledUnwritten(self: *Checker, pos: u32) bool {
    return sema.methodCalledUnwritten(self.ctx, self.nominal.sym, pos);
}

/// A requirement on a parameter that has the bounds of the method
/// being checked (`sema.widenOwnerBounds`) is decided here, by those
/// bounds and its type's, never left for the type's instances, which
/// may not call the method. Copying, keeping, and crossing are the
/// type's alone (`checkOwnerBounds`), so they are left as for any
/// method of the type.
pub fn decidedByOwnerBounds(self: *Checker, param: SymbolId, req: Requirement, pos: u32) Error!bool {
    if (!sema.ownerWidened(self.ctx, param)) return false;
    const api = tc.apiOf(req) orelse return false;
    if (tc.ownershipApi(api)) return false;
    if (!tc.boundsGive(self.ctx, self.ctx.symbols.items[param], req, api)) {
        try tc.reportUnbounded(self.ctx, pos, param, api, try self.ctx.arena.allocator().print("{s}", .{req.describe()}));
    }
    return true;
}

/// What a method's own bounds (`fun Wrap[T: Print].show(?@)`) may add
/// to its type's: none it names already, given or implied, and none of
/// the facts of how a `T` is copied, kept, or crosses, which every
/// method of the type shares and the type's bounds say.
pub fn checkOwnerBounds(self: *Checker, type_sym: SymbolId, node: Sexp, pos: u32, bounds: []const sema.OwnerBound) Error!void {
    const sym = self.ctx.symbols.items[type_sym];
    const tparams = sym.type_params orelse &.{};
    const keyword = if (node.isKind(.generic_enum)) "enum" else "obj";
    const mname = for (sym.fields orelse &.{}) |f| {
        if (f.is_method and f.decl_pos == pos) break f.name;
    } else "?";
    for (bounds) |b| {
        if (b.param >= tparams.len) continue;
        const param = self.ctx.symbols.items[tparams[b.param]];
        const has = sema.boundApis(self.ctx, param);
        const header = try boundedHeader(self, keyword, sym.name, tparams, std.math.maxInt(u32), "");
        var it = b.apis.iterator();
        while (it.next()) |api| {
            if (tc.ownershipApi(api)) {
                try self.err(pos, "`{s}.{s}` bounds `{s}` by `{s}`, which says how a `{s}` is copied, kept, or sent, the same in every method: bound the type, `{s}`", .{ sym.name, mname, param.name, @tagName(api), param.name, try boundedHeader(self, keyword, sym.name, tparams, b.param, @tagName(api)) });
            } else if (has.contains(api)) {
                try self.err(pos, "`{s}.{s}` repeats `{s}: {s}`, which `{s}` already gives: a method's bounds add to its type's", .{ sym.name, mname, param.name, @tagName(api), header });
            }
        }
        for (b.user_apis) |u| {
            const uname = try sema.apiName(self.ctx, u);
            const builds = try sema.builtInSupers(self.ctx, &.{u});
            var bit = builds.iterator();
            const moves: ?sema.Api = while (bit.next()) |api| {
                if (tc.ownershipApi(api)) break api;
            } else null;
            if (moves) |api| {
                try self.err(pos, "`{s}.{s}` bounds `{s}` by `{s}`, which builds on `{s}`, which says how a `{s}` is copied, kept, or sent, the same in every method: bound the type, `{s}`", .{ sym.name, mname, param.name, uname, @tagName(api), param.name, try boundedHeader(self, keyword, sym.name, tparams, b.param, uname) });
                continue;
            }
            if (try sema.provides(self.ctx, try self.ctx.intern(.{ .type_var = tparams[b.param] }), u) != null) {
                try self.err(pos, "`{s}.{s}` repeats `{s}: {s}`, which `{s}` already gives: a method's bounds add to its type's", .{ sym.name, mname, param.name, uname, header });
            }
        }
    }
}

/// `obj Wrap[T: Copy]`: the type's header with `bound` added to
/// parameter `at`'s bounds.
pub fn boundedHeader(self: *Checker, keyword: []const u8, name: []const u8, tparams: []const SymbolId, at: u32, bound: []const u8) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s} {s}[", .{ keyword, name });
    for (tparams, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        const sym = self.ctx.symbols.items[p];
        try out.appendSlice(a, sym.name);
        if (i != at and !sema.hasBounds(sym)) continue;
        const written = try sema.formatBounds(self.ctx, a, sym, null);
        try out.print(a, ": {s}{s}{s}", .{ written, if (i == at and written.len > 0) " + " else "", if (i == at) bound else "" });
    }
    try out.appendSlice(a, "]");
    return out.items;
}

/// A literal operand next to a generic `T` becomes a `T`, so every
/// `T` must hold it: a float literal needs a float `T`, an integer
/// one a `T` that holds its value.
pub fn requireHoldsLiteral(self: *Checker, param: SymbolId, lit_ty: TypeId, lit: Sexp, pos: u32, op: []const u8) Error!void {
    if (ViewCheck.integerOnlyOp(lit)) |int_op| try require(self, param, .integer, self.startOf(int_op), @tagName(int_op.kind().?));
    if (lit_ty == self.t().float_literal_id) try require(self, param, .float, pos, op);
    if (lit_ty == self.t().int_literal_id) if (constInt(self, lit)) |v| try require(self, param, .{ .fits = v }, pos, op);
    if (tc.wholeDivision(self.ctx.source, lit)) |div| try require(self, param, .whole_division, self.startOf(div), CallCheck.sourceText(self, div));
}

pub fn synthNeg(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Neg.operand(e);
    const ty = try ViewCheck.synthOperandValue(self, operand);
    if (self.isPoison(ty)) return ty;
    const lane = if (sema.simdOf(self.ctx, ty)) |v| v.elem else ty;
    if (lane != ty) switch (self.ctx.types.get(lane)) {
        .int => |info| if (info.signed) return ty,
        .float => return ty,
        else => {},
    };
    if (lane != ty) {
        try self.errAt(operand, "operator `-` negates signed integer or float lanes; got `{s}`", .{try self.tyName(ty)});
        return self.t().invalid_id;
    }
    switch (self.ctx.types.get(ty)) {
        .int => |info| {
            if (!info.signed) {
                try self.errAt(operand, "cannot negate a value of unsigned type `{s}`", .{try self.tyName(ty)});
                return self.t().invalid_id;
            }
            // A constant operand is negated now, so the result must fit.
            try BuiltinCheck.checkLiteralFits(self, e, ty);
        },
        .float, .int_literal, .float_literal => {},
        .type_var => |tv| try require(self, tv, .signed, self.startOf(operand), "-"),
        else => {
            try self.errAt(operand, "operator `-` requires a numeric operand; got `{s}`", .{try self.tyName(ty)});
            return self.t().invalid_id;
        },
    }
    return ty;
}

pub fn synthEquality(self: *Checker, e: Sexp) Error!TypeId {
    const op = @tagName(e.kind().?);
    const l = ir.get(e, .left);
    const r = ir.get(e, .right);
    // A contextual operand (`.red`, `.dot(at: p)`, `none`) takes the
    // type of the value the other side gives. `none` and a bare
    // `.variant` test which variant it holds, and compare no payload;
    // a payload literal compares its payload, so it needs `==`.
    if (tc.isContextual(self.ctx.source, l) or tc.isContextual(self.ctx.source, r)) {
        const lit, const other = if (tc.isContextual(self.ctx.source, r)) .{ r, l } else .{ l, r };
        const ty = try PatternCheck.synthExpr(self, other);
        // An `==` operand is read (Core §3). `none` and a bare
        // `.variant` test a value made there and drop it with the
        // test; any other operand whose value may move is read where
        // it is (`readLeaf`), as is a payload literal's operand and
        // the literal, a value made there.
        const owns = !self.isPoison(ty) and sema.moves(self.ctx, ty) != .no;
        if (owns and (lit.isKind(.call) or ViewCheck.hands(self, other).kind != .made)) try ViewCheck.readLeaf(self, other);
        const reached = try ViewCheck.readThrough(self, other, ty, sema.unwrapViews(self.ctx, ty));
        // Beside an error, a member with fields is named with its set
        // (`A.x(n: 3)`), as it is made where it fails.
        if (lit.isKind(.call) and ir.Call.callee(lit).isKind(.enum_lit) and !self.isPoison(reached)) {
            const subject = sema.unwrapOptionals(self.ctx, sema.unwrapViews(self.ctx, reached));
            if (sema.isErrorSet(self.ctx, subject) or subject == self.t().any_error_id) {
                const name = ir.EnumLit.name(ir.Call.callee(lit));
                const set = if (sema.isErrorUnion(self.ctx, subject)) try BuiltinCheck.unionMemberSet(self, subject, name) else if (subject == self.t().any_error_id) try BuiltinCheck.resolveErrorName(self, name) else subject;
                if (self.isPoison(set)) return self.t().bool_id;
                const named = try self.ctx.arena.allocator().print("{s}{s}", .{ try self.tyName(set), CallCheck.sourceText(self, lit) });
                if (self.ctx.types.get(sema.unwrapViews(self.ctx, reached)) == .optional) {
                    try self.errAt(lit, "an error member compared is named with its set, beside the error an optional holds: `if {s} as e`, then `e == {s}`", .{ CallCheck.sourceText(self, other), named });
                } else try self.errAt(lit, "an error member compared is named with its set: write `{s}`", .{named});
                return self.t().bool_id;
            }
        }
        // A bare `.name` tests which variant the value holds, one
        // with a payload too (SPEC §5, "Comparing").
        if (lit.isKind(.enum_lit) and !self.isPoison(reached)) {
            const subject = sema.unwrapViews(self.ctx, if (self.ctx.types.get(reached) == .optional) self.ctx.types.get(reached).optional else reached);
            // Beside an error that may carry fields, `.name` tests the
            // member, of the one set the error may be that has it.
            if (sema.setHasFields(self.ctx, subject) or subject == self.t().any_error_id) {
                const name = ir.EnumLit.name(lit);
                const set = if (sema.isErrorUnion(self.ctx, subject)) try BuiltinCheck.unionMemberSet(self, subject, name) else if (subject == self.t().any_error_id) try BuiltinCheck.resolveErrorName(self, name) else blk: {
                    if ((try sema.lookupVariant(self.ctx, subject, self.text(name))) == null) {
                        try PatternCheck.reportMissingVariant(self, subject, self.text(name), srcPos(name, 0));
                        break :blk self.t().invalid_id;
                    }
                    break :blk subject;
                };
                try self.ctx.recordType(lit, set);
                return self.t().bool_id;
            }
            if (sema.enumVariantCount(self.ctx, subject) != null and !sema.isErrorSet(self.ctx, subject)) {
                if (try sema.lookupVariant(self.ctx, subject, self.text(ir.EnumLit.name(lit)))) |_| {
                    try self.ctx.recordType(lit, reached);
                    return self.t().bool_id;
                }
            }
        }
        // A payload literal beside an optional is its payload's value,
        // which `==` compares with the optional as it is: no lift.
        const want = if (lit.isKind(.call) and self.ctx.types.get(reached) == .optional) sema.unwrapOptionals(self.ctx, reached) else reached;
        try ViewCheck.checkExpr(self, lit, want);
        if (lit.isKind(.call)) {
            try checkEquatable(self, reached, l, op);
            if (self.ctx.typeOf(lit)) |lit_ty| if (!self.isPoison(lit_ty) and sema.moves(self.ctx, lit_ty) != .no) try ViewCheck.readLeaf(self, lit);
        }
        return self.t().bool_id;
    }
    // `x == K.name`, a variant named with its enum, one with a payload
    // too: a test of which variant `x` holds (SPEC §5, "Comparing").
    for ([2]Sexp{ l, r }, 0..) |side, i| {
        if (!side.isKind(.member)) continue;
        const nt = (try CallCheck.namedType(self, ir.Member.object(side))) orelse continue;
        if (nt.sym.flags.error_set) {
            if (try errorMemberTest(self, side, if (i == 0) r else l, nt)) |ty| return ty;
            continue;
        }
        if (nt.sym.kind != .nominal_type) continue;
        // A plain enum's values compare as they are.
        const payloads = for (nt.sym.fields orelse &.{}) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) break true;
        } else false;
        if (!payloads) continue;
        const other = if (i == 0) r else l;
        const ty = try synthEqOperand(self, other);
        const value = sema.unwrapViews(self.ctx, ty);
        if (!self.isPoison(value) and value == try CallCheck.namedTypeValue(self, nt) and (try sema.lookupVariant(self.ctx, value, self.text(ir.Member.name(side)))) != null) {
            // Read as `x == .name` reads it: a value made here is
            // dropped by the test, any other owner read in place.
            if (sema.moves(self.ctx, ty) != .no and ViewCheck.hands(self, other).kind != .made) try ViewCheck.readLeaf(self, other);
            try self.ctx.recordType(side, value);
            try self.ctx.recordMemberTest(e);
            return self.t().bool_id;
        }
        const side_ty = try synthEqOperand(self, side);
        if (self.isPoison(ty) or self.isPoison(side_ty)) return self.t().bool_id;
        const a, const b = if (i == 0) .{ side_ty, ty } else .{ ty, side_ty };
        return finishEquality(self, e, l, r, a, b, op);
    }
    // A viewed operand compares as the value it reaches, and an
    // array literal beside an array takes its type.
    const l_array = l.isKind(.array) or l.isKind(.array_fill);
    const r_array = r.isKind(.array) or r.isKind(.array_fill);
    var a: TypeId = undefined;
    var b: TypeId = undefined;
    if (l_array != r_array) {
        const lit, const other = if (l_array) .{ l, r } else .{ r, l };
        const other_ty = try ViewCheck.synthReached(self, other);
        if (self.ctx.types.get(other_ty) == .array) {
            try ViewCheck.checkExpr(self, lit, other_ty);
            try checkEquatable(self, other_ty, l, op);
            return self.t().bool_id;
        }
        const lit_ty = try ViewCheck.synthReached(self, lit);
        a, b = if (l_array) .{ lit_ty, other_ty } else .{ other_ty, lit_ty };
    } else {
        const saved = self.beside;
        defer self.beside = saved;
        self.beside = .{ .node = l, .other = r };
        a = try synthEqOperand(self, l);
        self.beside = .{ .node = r, .other = l, .ty = a };
        b = try synthEqOperand(self, r);
    }
    if (self.isPoison(a) or self.isPoison(b)) return self.t().bool_id;
    return finishEquality(self, e, l, r, a, b, op);
}

/// `e == E.name`, where member `name` of set `nt` has fields: a test
/// of which member the error `other` is, which compares no fields
/// (SPEC §13, "Comparing"). Null for a member without fields, which
/// compares as any value does.
pub fn errorMemberTest(self: *Checker, side: Sexp, other: Sexp, nt: Checker.NamedType) Error!?TypeId {
    const name = self.text(ir.Member.name(side));
    const m = for (nt.sym.fields orelse &.{}) |f| {
        if (f.is_variant and std.mem.eql(u8, f.name, name)) break f;
    } else return null;
    if (m.payload == null or m.payload.?.len == 0) return null;
    const set = try CallCheck.namedTypeValue(self, nt);
    const ty = try synthEqOperand(self, other);
    const value = sema.unwrapViews(self.ctx, ty);
    if (self.isPoison(value) or self.isPoison(set)) return self.t().bool_id;
    const within = value == self.t().any_error_id or value == set or (sema.isErrorUnion(self.ctx, value) and sema.errorSubset(self.ctx, set, value));
    if (!within) {
        try self.errAt(other, "cannot compare `{s}` with `{s}`", .{ try self.tyName(ty), try self.tyName(set) });
        return self.t().bool_id;
    }
    // Read as `x == .name` reads it: a value made here is dropped by
    // the test, any other owner read in place.
    if (sema.moves(self.ctx, ty) != .no and ViewCheck.hands(self, other).kind != .made) try ViewCheck.readLeaf(self, other);
    try self.ctx.recordType(side, set);
    try self.ctx.recordErrorMember(side);
    return self.t().bool_id;
}

/// Whether `e` names an error member: `.name`, `E.name`, or one made
/// with its fields, `E.name(...)`.
pub fn namesErrorMember(self: *Checker, e: Sexp) bool {
    if (e.isKind(.enum_lit) or self.ctx.isErrorMember(e)) return true;
    if (!e.isKind(.call) or !ir.Call.callee(e).isKind(.member)) return false;
    const ty = self.ctx.typeOf(e) orelse return false;
    return sema.isErrorSet(self.ctx, sema.unwrapViews(self.ctx, ty)) and self.ctx.typeOf(ir.Call.callee(e)) == null;
}

/// `l == r` once both operands are typed, `a` and `b`: each an
/// optional of a view as the optional of the value it reaches
/// (`comparedAs`).
pub fn finishEquality(self: *Checker, e: Sexp, l: Sexp, r: Sexp, a_ty: TypeId, b_ty: TypeId, op: []const u8) Error!TypeId {
    const a = try comparedAs(self, a_ty);
    const b = try comparedAs(self, b_ty);
    // Two optionals of text compare by their bytes, as two texts do.
    if (a != b and textOptionals(self.ctx, a, b)) return self.t().bool_id;
    if (try ViewCheck.byteBeside(self, .{ l, r }, a, b) != null) return self.t().bool_id;
    if (try literalBesideSlot(self, l, r, a, b)) return self.t().bool_id;
    // Lane by lane: a mask. (An optional vector has no `==`, which
    // the optional's comparison reports.)
    const optional = self.ctx.types.get(a) == .optional or self.ctx.types.get(b) == .optional;
    if (!optional and (sema.simdOf(self.ctx, a) != null or sema.simdOf(self.ctx, b) != null)) {
        const vt = try StdFormCheck.simdOperands(self, e, op, .equatable, a, b);
        return if (self.isPoison(vt)) vt else StdFormCheck.maskOf(self, self.ctx.types.get(vt).simd);
    }
    // An operand whose value may move (an owner, a unique value, or
    // a type parameter's, which emit consumes) is read where it is,
    // and a temporary of it is dropped with its statement; a view
    // compared owns nothing.
    for ([2]Sexp{ l, r }) |operand| {
        const own = self.ctx.typeOf(operand) orelse continue;
        if (!self.isPoison(own) and sema.moves(self.ctx, own) != .no) try ViewCheck.readLeaf(self, operand);
    }
    if (sema.isNumeric(self.ctx, a) and sema.isNumeric(self.ctx, b)) {
        _ = try checkNumericComparison(self, l, r, a, b, op);
        return self.t().bool_id;
    }
    if (try comparesWithOptional(self, a, b, r, l, op)) {
        try checkEquatable(self, a, l, op);
        return self.t().bool_id;
    }
    if (try comparesWithOptional(self, b, a, l, l, op)) {
        try checkEquatable(self, b, r, op);
        return self.t().bool_id;
    }
    const ta = self.ctx.types.get(a);
    const tb = self.ctx.types.get(b);
    if (ta == .type_var or tb == .type_var) {
        // A `T` compares with a `T`, or with a literal every `T` holds.
        const tv_ty = if (ta == .type_var) a else b;
        if (!meetsTypeVar(self, tv_ty, if (ta == .type_var) b else a, .equatable)) {
            try cannotCompare(self, l, r, a, b);
            return self.t().bool_id;
        }
        const tv = self.ctx.types.get(tv_ty).type_var;
        try require(self, tv, .equatable, self.startOf(l), op);
        if (ta == .type_var) try requireHoldsLiteral(self, tv, b, r, self.startOf(l), op) else try requireHoldsLiteral(self, tv, a, l, self.startOf(l), op);
        return self.t().bool_id;
    }
    // Any error compares with a member of any error set, and a union
    // with a member of a set it joins: a bare member tests which
    // member it is, one with fields compares them too. Two errors
    // compare whole when their set has `==`, which `error`, of any
    // set, has not.
    const any_err = self.t().any_error_id;
    const joined = sema.isErrorSet(self.ctx, a) and sema.isErrorSet(self.ctx, b) and (sema.errorSubset(self.ctx, a, b) or sema.errorSubset(self.ctx, b, a));
    if (joined or (a == any_err and sema.isErrorValue(self.ctx, b)) or (b == any_err and sema.isErrorValue(self.ctx, a))) {
        for ([2]Sexp{ l, r }, [2]TypeId{ a, b }) |side, ty| if (namesErrorMember(self, side)) {
            if (side.isKind(.call)) try checkEquatable(self, ty, side, op);
            return self.t().bool_id;
        };
        if (a == any_err and b == any_err) {
            try self.errAt(l, "an `error` may be of any set, and has no `{s}` of its own: match it, or compare it with a member (`e == E.name`)", .{op});
            return self.t().bool_id;
        }
        // Beside `error`, the other's set decides; of two sets, the
        // wider.
        const set = if (a == any_err) b else if (b == any_err) a else if (sema.errorSubset(self.ctx, a, b)) b else a;
        try checkEquatable(self, set, l, op);
        return self.t().bool_id;
    }
    // A String, boxed or not, compares with a `?String` or a String by
    // content.
    const string_ty = self.t().string_id;
    const string_view_ty = self.t().string_view_id;
    // Comparing reads both texts: a `Static` beside a `?String`.
    const a_read = if (a == self.t().static_id) string_view_ty else a;
    const b_read = if (b == self.t().static_id) string_view_ty else b;
    const ta_text = tc.stringOrBoxed(self.ctx, a_read);
    const tb_text = tc.stringOrBoxed(self.ctx, b_read);
    // A shared handle is not text: it has no `==`, and its content is
    // compared through a view, `?a == ?b`.
    const handles = sema.accessThroughShared(self.ctx, a) or sema.accessThroughShared(self.ctx, b);
    if (!handles and (ta_text == string_ty or tb_text == string_ty) and (ta_text == string_ty or ta_text == string_view_ty) and (tb_text == string_ty or tb_text == string_view_ty)) return self.t().bool_id;
    if (a_read != b_read) {
        try cannotCompare(self, l, r, a, b);
        return self.t().bool_id;
    }
    // `x == K.name` tests which variant `x` holds, comparing no
    // payload, so it needs no `==` on the payloads.
    if (try namesVariantOf(self, l, a) or try namesVariantOf(self, r, a)) {
        try self.ctx.recordMemberTest(e);
        return self.t().bool_id;
    }
    try checkEquatable(self, a, l, op);
    return self.t().bool_id;
}

/// Whether `operand` is `K.name`, naming a variant of `ty`, an enum
/// with a payload variant (an enum of plain variants compares by
/// value already).
pub fn namesVariantOf(self: *Checker, operand: Sexp, ty: TypeId) Error!bool {
    if (!operand.isKind(.member) or sema.isErrorSet(self.ctx, ty)) return false;
    const obj = ir.Member.object(operand);
    if (obj != .src or self.ctx.typeOf(obj) != null) return false;
    if (sema.enumVariantCount(self.ctx, ty) == null or (try sema.notEquatable(self.ctx, ty, null)) == null) return false;
    return (try sema.lookupVariant(self.ctx, ty, self.text(ir.Member.name(operand)))) != null;
}

/// An operand of `==`, as the value it reaches. A shared handle has
/// no `==`; `?h` of a name holding one, `*T`, views the handle's value
/// as a `?T` (CORE §4), so `?a == ?b` compares two handles' contents.
pub fn synthEqOperand(self: *Checker, e: Sexp) Error!TypeId {
    if (e.isKind(.read)) if (sharedContent(self, ir.Read.operand(e))) |content| {
        const view = if (content == self.t().string_id) self.t().string_view_id else try self.ctx.intern(.{ .read_view = content });
        try ViewCheck.checkExpr(self, e, view);
        return ViewCheck.readThrough(self, e, view, sema.unwrapViews(self.ctx, view));
    };
    return ViewCheck.synthReached(self, e);
}

/// The type `==` compares a value of `ty` as: a view inside an
/// optional as the value it reaches (`(?Int)?` as `Int?`), as a
/// viewed operand compares (SPEC §5); `ty` itself otherwise.
pub fn comparedAs(self: *Checker, ty: TypeId) Error!TypeId {
    const inner = switch (self.ctx.types.get(ty)) {
        .optional => |i| i,
        else => return ty,
    };
    const reached = try comparedAs(self, sema.unwrapViews(self.ctx, inner));
    return if (reached == inner) ty else self.ctx.intern(.{ .optional = reached });
}

/// The value a name holding a shared handle `*T` reaches, `T`, or null.
pub fn sharedContent(self: *Checker, e: Sexp) ?TypeId {
    if (e != .src) return null;
    const sym = CallCheck.lookupQuiet(self, e) orelse return null;
    const ty = self.ctx.symbols.items[sym].ty;
    return switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
        .shared => |inner| if (self.ctx.types.get(inner) == .function) null else sema.frozenValue(self.ctx, inner) orelse inner,
        else => null,
    };
}

/// Whether `a` and `b` are optionals of text as deep as each other
/// (`String?` and `(?String)?`).
pub fn textOptionals(ctx: *const SemContext, a: TypeId, b: TypeId) bool {
    const ia = switch (ctx.types.get(a)) {
        .optional => |i| i,
        else => return false,
    };
    const ib = switch (ctx.types.get(b)) {
        .optional => |i| i,
        else => return false,
    };
    if (tc.isText(ctx, ia) and tc.isText(ctx, ib)) return true;
    return textOptionals(ctx, ia, ib);
}

/// Whether `opt` is a `T?` and `value` a `T` (or a literal that is
/// one): the two compare equal when the optional holds the value. A
/// literal beside a generic `T?` must fit every `T` (`op` at `at`).
pub fn comparesWithOptional(self: *Checker, opt: TypeId, value: TypeId, value_node: Sexp, at: Sexp, op: []const u8) Error!bool {
    const inner = switch (self.ctx.types.get(opt)) {
        .optional => |i| i,
        else => return false,
    };
    const literal = value == self.t().int_literal_id or value == self.t().float_literal_id;
    const param: ?SymbolId = switch (self.ctx.types.get(inner)) {
        .type_var => |tv| tv,
        else => null,
    };
    // Text beside an optional of text compares by its bytes, whatever
    // its type, as two texts do.
    if (tc.isText(self.ctx, inner) and tc.isText(self.ctx, value) and value != inner) return true;
    // An error of a set the optional's holds compares as one of it,
    // a code beside a code: neither set has fields.
    const widens = sema.isErrorSet(self.ctx, value) and sema.isErrorSet(self.ctx, inner) and sema.errorSubset(self.ctx, value, inner) and
        !sema.setHasFields(self.ctx, value) and !sema.setHasFields(self.ctx, inner);
    if (value != inner and !widens and !sema.readsAsStringView(self.ctx, value, inner) and !(literal and (param != null or tc.compatible(self.ctx, value, inner)))) return false;
    if (param) |tv| try requireHoldsLiteral(self, tv, value, value_node, self.startOf(at), op);
    try ViewCheck.recordAdapted(self, value_node, value, inner);
    return true;
}

/// Numeric equality: same rules as arithmetic, with operands already synthesized.
pub fn checkNumericComparison(self: *Checker, l: Sexp, r: Sexp, a: TypeId, b: TypeId, op: []const u8) Error!void {
    const a_lit = a == self.t().int_literal_id or a == self.t().float_literal_id;
    const b_lit = b == self.t().int_literal_id or b == self.t().float_literal_id;
    // Beside a float literal, integer literals compare as floats.
    if (a == self.t().int_literal_id and b == self.t().float_literal_id) try ViewCheck.checkWholeDivision(self, l);
    if (b == self.t().int_literal_id and a == self.t().float_literal_id) try ViewCheck.checkWholeDivision(self, r);
    if (a_lit and !b_lit) return ViewCheck.checkExpr(self, l, b);
    if (b_lit and !a_lit) return ViewCheck.checkExpr(self, r, a);
    // Two literal operands are compared as `Int`s.
    if (a == self.t().int_literal_id and b == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, l);
        try ViewCheck.defaultIntLiteral(self, r);
    }
    if (!a_lit and a != b) {
        try self.errAt(l, "cannot compare `{s}` with `{s}` using `{s}`", .{ try self.tyName(a), try self.tyName(b), op });
    }
}

/// `==` compares values of `ty` (`sema.notEquatable`); inside a
/// generic body, in the instances where it compares the parameters
/// `ty` holds.
pub fn checkEquatable(self: *Checker, ty: TypeId, node: Sexp, op: []const u8) Error!void {
    if (self.isPoison(ty)) return;
    var params: std.ArrayList(SymbolId) = .empty;
    defer params.deinit(self.ctx.allocator);
    if (try sema.notEquatable(self.ctx, ty, &params)) |n| {
        return self.errAt(node, "`{s}` is not defined for `{s}`: {s}", .{ op, try self.tyName(ty), try tc.notEquatableReason(self.ctx, n) });
    }
    for (params.items) |tv| try require(self, tv, .equatable, self.startOf(node), op);
}

pub fn synthBlock(self: *Checker, node: Sexp, expected: ?TypeId) Error!TypeId {
    const stmts = ir.Block.stmts(node);
    if (stmts.len == 0) {
        if (expected) |e| if (!self.isPoison(e) and e != self.t().void_id) {
            try self.errAt(node, "empty block where a `{s}` is expected", .{try self.tyName(e)});
        };
        return self.t().void_id;
    }
    const prev = self.enter(node);
    defer self.scope = prev;
    for (stmts[0 .. stmts.len - 1]) |*s| try self.checkRewritten(s, StmtCheck.checkStmt, .{});
    return self.checkRewritten(&stmts[stmts.len - 1], Checker.synthTail, .{expected});
}

/// `a ?? b`: the value inside optional `a`, or `b` when `a` is `none`.
pub fn synthCoalesce(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
    const left = ir.@"??".left(e);
    const right = ir.@"??".right(e);
    const opt = try PatternCheck.synthExpr(self, left);
    if (self.isPoison(opt)) {
        _ = try PatternCheck.synthExpr(self, right);
        return opt;
    }
    const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, opt))) {
        .optional => |i| i,
        else => {
            try self.errAt(left, "`??` needs an optional on its left; this expression has type `{s}`", .{try self.tyName(opt)});
            _ = try PatternCheck.synthExpr(self, right);
            return self.t().invalid_id;
        },
    };
    // A view of an optional gives up nothing; the value inside stays
    // where it is. Otherwise a read reads the value inside where
    // it is, and a take takes it, which the ownership checker requires
    // of each operand.
    const through_view = sema.unwrapViews(self.ctx, opt) != opt;
    if (through_view and try ViewCheck.cannotCopy(self, inner, self.startOf(left), "copies out with `??` a value")) {
        try viewGivesUp(self, left, opt);
        return self.t().invalid_id;
    }
    _ = try ViewCheck.readThrough(self, left, opt, sema.unwrapViews(self.ctx, opt));
    const view_result = try joinFallback(self, fallbackType(self, inner, expected), right);
    const result = if (try fallbackCopy(self, e, left, opt, view_result, right, expected)) |value| result: {
        if (self.isPoison(value)) {
            _ = try PatternCheck.synthExpr(self, right);
            return value;
        }
        break :result fallbackType(self, value, expected);
    } else view_result;
    if (try errorAsFallback(self, right, result, "??")) return result;
    try ViewCheck.checkExpr(self, right, result);
    try recordFallbackLiterals(self, right);
    return result;
}

/// A fallback, after `??` or `catch`, that names an error where a
/// value is wanted: an error is returned, not given, so the hint
/// writes the jump (`?? return Config.missing`). True when it
/// reported.
pub fn errorAsFallback(self: *Checker, fallback: Sexp, wanted: TypeId, op: []const u8) Error!bool {
    if (tc.isJumpNode(fallback) or self.isPoison(wanted) or sema.isErrorSet(self.ctx, wanted)) return false;
    const ty = ty: {
        self.tentative += 1;
        defer self.tentative -= 1;
        break :ty try FlowCheck.synthQuiet(self, fallback);
    };
    if (!sema.isErrorSet(self.ctx, ty)) return false;
    const shown = CallCheck.sourceText(self, fallback);
    try self.errAt(fallback, "`{s}` is an error, and `{s}` needs a fallback of type `{s}`; to fail with it, return it: `{s} return {s}`", .{ shown, op, try self.tyName(wanted), op, shown });
    return true;
}

/// The `T` that `a ?? b` or `a catch b` (`e`) gives when the payload
/// of `holder`, `a`, of type `holder_ty`, is a view `?T` or `!T`
/// (`sema.payloadViewed`), and the fallback `b` is no view of it: it
/// meets neither the view nor `view_result`, the type the form has
/// when it gives the view (so `none` where an optional view goes, a
/// jump, and another view leave it the view), and it is the value, or
/// its type comes only from its context (`.point`). The value the payload
/// views is copied out where `a` has one, as `if a as v` then `v`
/// else `b` copies `v` (Core sentence 1), and the form is recorded
/// (`SemContext.recordPayloadCopy`). A `T` that does not copy is
/// reported, with poison returned, and so is a `T` that may not copy in
/// every instance of a generic body. Null where the form gives the
/// view.
pub fn fallbackCopy(self: *Checker, e: Sexp, holder: Sexp, holder_ty: TypeId, view_result: TypeId, fallback: Sexp, expected: ?TypeId) Error!?TypeId {
    const view = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, holder_ty))) {
        .optional => |inner| inner,
        .fallible => |inner| inner.ok,
        else => return null,
    };
    // A `?String` views a `String`, which never copies: reported.
    const viewed = sema.payloadViewed(self.ctx, holder_ty) orelse if (view == self.t().string_view_id) self.t().string_id else return null;
    const copies = copies: {
        const ty = ty: {
            self.tentative += 1;
            defer self.tentative -= 1;
            break :ty try FlowCheck.synthQuiet(self, fallback);
        };
        // A fallback whose type only its context gives (`.point`,
        // `List()`) is a value made there, never a view.
        if (self.isPoison(ty)) break :copies true;
        if (tc.meets(self.ctx, ty, view) or tc.meets(self.ctx, ty, view_result)) break :copies false;
        // One that fits neither the view nor the value is reported
        // against the view, as it was; `none` alone, where no optional
        // is expected, fits neither, so a `??` in a fallback decides
        // the same with or without its context.
        break :copies tc.meets(self.ctx, ty, fallbackType(self, viewed, expected));
    };
    // Decided where the form is checked for good: a quiet pass may
    // decide otherwise without its context.
    if (self.ctx.quiet == 0) try self.ctx.recordPayloadCopy(e, copies);
    if (!copies) return null;
    // Only a value that copies is copied out of a view; in a generic
    // body, a `T` that may not copy in every instance is not, as a
    // view read where its `T` is expected is not (`checkActual`).
    const answer = sema.copies(self.ctx, viewed);
    if (answer != .yes) {
        const name = try self.tyName(viewed);
        const fix = try ViewCheck.spliced(self, e, &.{fallback}, &.{try viewedFallbackText(self, fallback, viewed)});
        const head = "`{s}` would copy out the `{s}` that `{s}` views, since its fallback is a value, not a view; only a value that copies is copied out of a view, and ";
        if (answer == .depends) {
            try self.errAt(e, head ++ "`{s}` may not copy in every instance: make the fallback a view, so the result is one: `{s}`", .{ CallCheck.sourceText(self, e), name, CallCheck.sourceText(self, holder), name, fix });
        } else try self.errAt(e, head ++ "{s} `{s}` {s}: make the fallback a view, so the result is one, and clone that for {s} `{s}` of its own: `+({s})`", .{ CallCheck.sourceText(self, e), name, CallCheck.sourceText(self, holder), tc.article(name), name, ViewCheck.movesBecause(self, viewed), tc.article(name), name, fix });
        return self.t().invalid_id;
    }
    return viewed;
}

/// A read view of the fallback `b` of `a ?? b`, as a hint writes it: a
/// variant literal names its enum, `?(Val.v(...))`, since only its
/// context gives `.v(...)` its type, and a call through a type is
/// parenthesized, since `?Val.v(...)` would view `Val`.
pub fn viewedFallbackText(self: *Checker, fallback: Sexp, viewed: TypeId) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    const src = CallCheck.sourceText(self, fallback);
    const variant = fallback.isKind(.enum_lit) or (fallback.isKind(.call) and ir.Call.callee(fallback).isKind(.enum_lit));
    if (variant) return a.print("?({s}{s})", .{ try self.tyName(viewed), src });
    if (fallback.isKind(.call) and ir.Call.callee(fallback).isKind(.member)) return a.print("?({s})", .{src});
    return a.print("?{s}", .{src});
}

/// The type of `a ?? b` or `a catch b` when `a` gives a `Static` and
/// the fallback is a `?String`: the `?String`, which reads the `Static`
/// (`readsAsStringView`), as a branch joins the two.
pub fn joinFallback(self: *Checker, result: TypeId, fallback: Sexp) Error!TypeId {
    if (result != self.t().static_id) return result;
    self.tentative += 1;
    defer self.tentative -= 1;
    const ty = try FlowCheck.synthQuiet(self, fallback);
    return if (tc.readValue(self.ctx, ty) == self.t().string_view_id) self.t().string_view_id else result;
}

/// The short forms a fallback gives (`sema.yieldedLeaves`) take their
/// enum's type from the value the fallback stands for, which Zig's
/// `orelse` and `catch` do not hand them: each is recorded to be
/// written with its type (`SemContext.recordTypedLiteral`). A payload
/// variant always is, being a struct of no type in Zig; a bare `.name`
/// is where it is a branch's or a block's value, since Zig joins an
/// enum literal with its enum only where it stands as the fallback
/// itself. An error set's member is its error value, typed already.
pub fn recordFallbackLiterals(self: *Checker, fallback: Sexp) Error!void {
    var leaves: std.ArrayList(Sexp) = .empty;
    defer leaves.deinit(self.ctx.allocator);
    try sema.yieldedLeaves(self.ctx.allocator, self.ctx.source, fallback, &leaves);
    for (leaves.items) |leaf| {
        const payload = leaf.isKind(.call) and ir.Call.callee(leaf).isKind(.enum_lit);
        if (!payload and !(leaf.isKind(.enum_lit) and !tc.sameNode(leaf, fallback))) continue;
        const ty = self.ctx.typeOf(leaf) orelse continue;
        if (self.isPoison(ty) or ty == self.t().any_error_id or sema.isErrorSet(self.ctx, sema.unwrapViews(self.ctx, ty))) continue;
        try self.ctx.recordTypedLiteral(leaf);
    }
}

/// The type of `a ?? b` or `a catch b`, where `a` gives an `inner`:
/// `inner`, or the optional its context expects, which lets the
/// fallback `b` be `none` or another optional. `inner` widens to it
/// only as itself (`meets`), or as a view held by value, which is
/// its value: a view held by address stays the view, and the whole
/// `??` or `catch` is copied out where its context expects the value
/// (`copiedOut`).
pub fn fallbackType(self: *Checker, inner: TypeId, expected: ?TypeId) TypeId {
    const e = expected orelse return inner;
    return switch (self.ctx.types.get(e)) {
        .optional => |i| if (tc.meets(self.ctx, inner, i) or (!sema.viewHeldAsPointer(self.ctx, inner) and tc.compatible(self.ctx, inner, i))) e else inner,
        else => inner,
    };
}

/// `expr catch handler`: the value of fallible `expr`, or `handler`.
/// `expr catch |err| handler` names the error for the handler; it
/// may be any error, since functions do not declare their errors.
pub fn synthCatch(self: *Checker, e: Sexp, expected: ?TypeId) Error!TypeId {
    const value = ir.Catch.value(e);
    const name = ir.Catch.name(e);
    const handler = ir.Catch.handler(e);
    const ty = try synthHandled(self, value);
    const prev = self.scope;
    defer self.scope = prev;
    if (name != .nil) {
        _ = self.enter(e);
        // The callee's set: `error` for a `T!`, or the set it declares.
        const set = if (self.ctx.types.get(ty) == .fallible) self.ctx.types.get(ty).fallible.set else self.t().any_error_id;
        if (self.ctx.symbolOf(name)) |sym| {
            (try self.ctx.symbolMut(sym)).ty = set;
            try self.ctx.recordType(name, set);
        }
    }
    if (self.isPoison(ty)) {
        _ = try PatternCheck.synthExpr(self, handler);
        return ty;
    }
    const inner = switch (self.ctx.types.get(ty)) {
        .fallible => |i| i.ok,
        else => {
            if (self.ctx.isConstMaker(value)) {
                try self.errAt(value, "`catch` needs a fallible expression, and `{s}` cannot fail: {s}, so it gives a `{s}`; write it without `catch`", .{ try ViewCheck.plainText(self, value), whyCannotFail(self, value), try self.tyName(ty) });
            } else try self.errAt(value, "`catch` needs a fallible expression; this expression has type `{s}` and cannot fail", .{try self.tyName(ty)});
            _ = try PatternCheck.synthExpr(self, handler);
            return self.t().invalid_id;
        },
    };
    // A `catch` whose value goes nowhere, a statement's or `_ =`'s,
    // may have a handler that gives nothing: then the `catch` gives
    // nothing, `run() catch |e| print(e)`. A handler that gives a
    // value gives the fallback, as anywhere (`run() catch 0`). A
    // value that owns what it must release is dropped visibly, by
    // `_ =`, so only there.
    if (tc.sameNode(e, self.discarded) and inner != self.t().void_id) {
        if (try FlowCheck.synthQuiet(self, handler) == self.t().void_id) {
            const owned = sema.typeHasDropGlue(self.ctx, inner) or sema.maybeDropGlue(self.ctx, inner);
            if (owned and !self.discard_named) {
                const shown = CallCheck.sourceText(self, value);
                try self.errAt(value, "`{s}` gives a `{s}`, which owns what it must release, and this `catch` throws it away: drop it by name, `_ = {s} catch ...`", .{ shown, try self.tyName(inner), shown });
            }
            try ViewCheck.checkExpr(self, handler, self.t().void_id);
            return self.t().void_id;
        }
    }
    const view_result = try joinFallback(self, fallbackType(self, inner, expected), handler);
    const result = if (try fallbackCopy(self, e, value, ty, view_result, handler, expected)) |copied| result: {
        if (self.isPoison(copied)) {
            _ = try PatternCheck.synthExpr(self, handler);
            return copied;
        }
        break :result fallbackType(self, copied, expected);
    } else view_result;
    if (try errorAsFallback(self, handler, result, "catch")) return result;
    try ViewCheck.checkExpr(self, handler, result);
    try recordFallbackLiterals(self, handler);
    return result;
}

/// `e!`: the value of fallible `e`; its failure goes to `fail_to`.
pub fn synthPropagate(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.Propagate.value(e);
    switch (self.body.fail_to) {
        .caller, .module => {},
        .deferred => try self.errAt(operand, "cannot use `!` inside `defer`; a deferred expression cannot propagate failure, so handle it with `catch`", .{}),
        .closure => try self.errAt(operand, "use of `!` propagation requires a fallible enclosing function; a closure body propagates failure only when its type can fail (`?fun(A) -> T!`), so handle it with `catch`", .{}),
        .drop => try self.errAt(operand, "a `drop` body cannot propagate failure; handle it with `catch`", .{}),
        .infallible => |name| {
            if (self.body.is_sub) {
                try self.errAt(operand, "use of `!` propagation requires the enclosing `{s}` to be fallible: `sub {s}!`", .{ self.text(name), CallCheck.headerText(self, name) });
            } else try self.errAt(operand, "use of `!` propagation requires the enclosing function `{s}` to declare a fallible return type (`-> T!`)", .{self.text(name)});
            try self.noteAt(name, "`{s}` declared here", .{self.text(name)});
        },
    }
    const ty = try synthHandled(self, operand);
    return switch (self.ctx.types.get(ty)) {
        .fallible => |f| {
            try checkFailsInto(self, operand, f.set);
            return f.ok;
        },
        .unknown, .invalid => ty,
        else => {
            if (self.ctx.isConstMaker(operand)) {
                try self.errAt(operand, "`!` needs a fallible operand, and `{s}` cannot fail: {s}, so it gives a `{s}`; write it without `!`", .{ try ViewCheck.plainText(self, operand), whyCannotFail(self, operand), try self.tyName(canonical(self, ty)) });
            } else try self.errAt(operand, "`!` needs a fallible operand; this expression has type `{s}` and cannot fail", .{try self.tyName(canonical(self, ty))});
            return ty;
        },
    };
}

/// Why a maker's call (`sema.ConstMaker`) cannot fail: its arguments
/// are constants that pass its check, or, for `time.duration`, its
/// duration form is one that cannot fail.
pub fn whyCannotFail(self: *Checker, call: Sexp) []const u8 {
    if (call.isKind(.call)) {
        const callee = ir.Call.callee(call);
        if (callee.isKind(.member) and std.mem.eql(u8, self.text(ir.Member.name(callee)), "duration")) {
            for (ir.Call.args(call)) |a| {
                const v = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
                if (constInt(self, v) == null and StdFormCheck.floatConst(self, v) == .unknown) return "its duration form cannot fail: a `Duration`, or an `Int` of `ns:`, `us:` or `ms:`";
            }
        }
    }
    if (call.isKind(.call)) {
        const callee = ir.Call.callee(call);
        if (callee.isKind(.member) and std.mem.eql(u8, self.text(ir.Member.name(callee)), "format")) return "its format string is known as Rig compiles and suits its type";
    }
    return "its arguments are constants that pass its check";
}

/// A failure with an error of `set` passes out of the function being
/// checked, by `x!`: the set the function declares must hold it.
pub fn checkFailsInto(self: *Checker, operand: Sexp, set: TypeId) Error!void {
    if (self.body.fail_to != .caller or self.isPoison(set)) return;
    const ret = self.ctx.types.get(self.body.ret);
    if (ret != .fallible or sema.errorSubset(self.ctx, set, ret.fallible.set)) return;
    const callee = if (operand.isKind(.call)) try StdFormCheck.calleeName(self, ir.Call.callee(operand)) else try ViewCheck.plainText(self, operand);
    const fname = try StmtCheck.bodyName(self);
    const declared = try self.tyName(self.body.ret);
    if (set == self.t().any_error_id) {
        // A call on a type parameter's instance: the body knows no set
        // its method fails with, so it takes any.
        if (operand.isKind(.call) and ir.Call.callee(operand).isKind(.member)) if (self.ctx.typeOf(ir.Member.object(ir.Call.callee(operand)))) |recv_ty| if (self.ctx.types.get(sema.unwrapViews(self.ctx, recv_ty)) == .type_var) {
            return self.errAt(operand, "`{s}` is a call on a `{s}`, whose method the body takes to fail with any error, and {s} declares `{s}`: catch it, or declare `{s}`", .{ callee, try self.tyName(sema.unwrapViews(self.ctx, recv_ty)), fname, declared, try anyErrorHeader(self) });
        };
        return self.errAt(operand, "`{s}` may fail with any error, and {s} declares `{s}`: catch it, or declare `{s}`", .{ callee, fname, declared, try anyErrorHeader(self) });
    }
    // A union joins declared sets, never a set parameter.
    if (sema.isSetParam(self.ctx, set) or sema.isSetParam(self.ctx, ret.fallible.set)) {
        return self.errAt(operand, "`{s}` may fail with `{s}`, which `{s}`, the error set {s} declares, does not hold: catch it", .{ callee, try self.tyName(set), try self.tyName(ret.fallible.set), fname });
    }
    return self.errAt(operand, "`{s}` may fail with `{s}`, which `{s}`, the error set {s} declares, does not hold: catch it, or declare a set that holds both (`error L = {s} | {s}`)", .{ callee, try self.tyName(set), try self.tyName(ret.fallible.set), fname, try self.tyName(ret.fallible.set), try self.tyName(set) });
}

/// `return err` with `err` of `actual`, an error set or `error`, in
/// a function returning `expected`, a `T!E`: `E` must hold it.
pub fn checkReturnedError(self: *Checker, e: Sexp, actual: TypeId, expected: TypeId) Error!void {
    try self.ctx.recordFailingLeaf(e);
    const declared = self.ctx.types.get(expected).fallible.set;
    if (self.isPoison(actual) or sema.errorSubset(self.ctx, actual, declared)) return;
    const fname = try StmtCheck.bodyName(self);
    const shown = try ViewCheck.plainText(self, e);
    if (actual == self.t().any_error_id) {
        return self.errAt(e, "`{s}` may be any error, and {s} declares `{s}`: narrow it with a `match` arm (`g: {s} =>`), or declare `{s}`", .{ shown, fname, try self.tyName(expected), try self.tyName(declared), try anyErrorHeader(self) });
    }
    if (self.ctx.isErrorMember(e)) {
        return self.errAt(e, "`{s}` is not in `{s}`, the error set {s} declares", .{ shown, try self.tyName(declared), fname });
    }
    const set = try self.tyName(actual);
    return self.errAt(e, "`{s}` is {s} `{s}` error, which `{s}`, the error set {s} declares, does not hold", .{ shown, tc.article(set), set, try self.tyName(declared), fname });
}

/// The header the function being checked would write to fail with
/// any error: `-> T!`, or `sub f()!`.
pub fn anyErrorHeader(self: *Checker) Error![]const u8 {
    const ret = self.ctx.types.get(self.body.ret);
    if (self.body.is_sub) return self.ctx.arena.allocator().print("sub {s}(...)!", .{self.text(self.body.name)});
    return self.ctx.arena.allocator().print("-> {s}!", .{try self.tyName(if (ret == .fallible) ret.fallible.ok else self.body.ret)});
}

/// A task's result, or a result an actor's method gives through a
/// handle, `ty`: waiting for it also fails with `task.Stop`, so a set
/// it declares must hold `Stop`. False once that is reported.
pub fn waitHoldsStop(self: *Checker, pos: u32, ty: TypeId, name: []const u8) Error!bool {
    const got = self.ctx.types.get(ty);
    if (got != .fallible or self.isPoison(got.fallible.set)) return true;
    if (try sema.setHoldsStop(self.ctx, got.fallible.set, self.ctx.arena.allocator())) return true;
    const set = try self.tyName(got.fallible.set);
    try self.err(pos, "`{s}` fails with `{s}`, and waiting for it also fails with `task.Stop`: join it into the set (`error L = {s} | task.Stop`)", .{ name, set, set });
    return false;
}

/// `e?`: the value inside optional `e`; when `e` is `none`, the
/// enclosing function returns `none`, so it must return an optional.
/// A resource inside `e` is handed over, so `e` cannot be a view.
pub fn synthPropagateNone(self: *Checker, e: Sexp) Error!TypeId {
    const operand = ir.PropagateNone.value(e);
    // A fallible call is handled here, by the one error below.
    const ty = try synthHandled(self, operand);
    if (self.isPoison(ty)) return ty;
    if (self.ctx.types.get(ty) == .fallible) {
        const shown = try ViewCheck.plainText(self, operand);
        try self.errAt(operand, "`?` propagates `none`, and `{s}` fails with an error instead: propagate the failure with `{s}!`, or handle it with `catch`", .{ shown, shown });
        return self.ctx.types.get(ty).fallible.ok;
    }
    const inner = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
        .optional => |i| i,
        else => {
            // `*w?` is `*(w?)`; propagating a gone value is `(*w)?`.
            if (tc.sameNode(e, self.shared_operand) and self.ctx.types.get(sema.unwrapViews(self.ctx, ty)) == .weak) {
                const shown = try ViewCheck.plainText(self, operand);
                try self.errAt(operand, "`*{s}?` is `*({s}?)`, and `{s}` is a weak handle, not an optional: to return `none` once its value is gone, write `(*{s})?`", .{ shown, shown, shown, shown });
                return self.t().invalid_id;
            }
            try self.errAt(operand, "`?` needs an optional operand; this expression has type `{s}`", .{try self.tyName(canonical(self, ty))});
            return self.t().invalid_id;
        },
    };
    switch (self.body.fail_to) {
        .deferred => return noneNotReturned(self, operand, "cannot use `?` inside `defer`; deferred code cannot return, so take the value out with `if x as v` or `??`"),
        // An inferred closure's type returns no optional.
        .closure => if (self.body.returns != null or !returnsOptional(self, self.body.ret)) {
            return noneNotReturned(self, operand, "a closure body returns `none` with `?` only when its type returns an optional (`?fun(A) -> T?`); take the value out with `if x as v` or `??`");
        },
        .drop => return noneNotReturned(self, operand, "a `drop` body cannot return `none` with `?`; take the value out with `if x as v` or `??`"),
        .caller, .infallible, .module => if (!returnsOptional(self, self.body.ret)) {
            const name = self.body.name;
            const shown = try ViewCheck.plainText(self, operand);
            if (name == .nil) {
                try self.errAt(operand, "use of `?` requires the enclosing function to return an optional (`-> T?`)", .{});
            } else if (self.body.is_sub) {
                try self.errAt(operand, "`?` returns `none` from `{s}`, which returns no value; handle the missing value with `{s} ?? fallback`, or `if {s} as {s}`", .{ self.text(name), shown, shown, bindingNameFor(shown) });
            } else {
                try self.errAt(operand, "use of `?` requires the enclosing function `{s}` to return an optional (`-> T?`); or handle the missing value with `{s} ?? fallback`", .{ self.text(name), shown });
                try self.noteAt(name, "`{s}` declared here", .{self.text(name)});
            }
            return self.t().invalid_id;
        },
    }
    const through_view = sema.unwrapViews(self.ctx, ty) != ty;
    if (through_view and (try ViewCheck.cannotCopy(self, inner, self.startOf(operand), "moves out of a view a value"))) {
        try viewGivesUp(self, operand, ty);
        return self.t().invalid_id;
    }
    _ = try ViewCheck.readThrough(self, operand, ty, sema.unwrapViews(self.ctx, ty));
    return inner;
}

/// `o ?? ...` or `o?` over a view `ty` of an optional that owns a
/// resource: the view can give a view of the value inside, not give
/// it up.
pub fn viewGivesUp(self: *Checker, operand: Sexp, ty: TypeId) Error!void {
    const place = if (operand.isKind(.move)) ir.Move.operand(operand) else operand;
    const shown = try ViewCheck.plainText(self, place);
    const sigil = if (self.ctx.types.get(ty) == .write_view and !place.isKind(.write)) "!" else "";
    const value = sema.unwrapViews(self.ctx, ty);
    const what = if (!sema.typeHasDropGlue(self.ctx, value) and sema.holdsWriteView(self.ctx, value)) "write view" else "resource";
    try self.errAt(operand, "a view cannot give up the {s} inside it; make a view of the value inside with `if {s}{s} as {s}`", .{ what, sigil, shown, bindingNameFor(shown) });
}

/// A name to suggest binding the value inside `shown` to, which
/// does not shadow it.
pub fn bindingNameFor(shown: []const u8) []const u8 {
    return if (std.mem.eql(u8, shown, "value")) "v" else "value";
}

/// `e?` where no `none` can be returned: the error, and no type.
pub fn noneNotReturned(self: *Checker, operand: Sexp, comptime msg: []const u8) Error!TypeId {
    try self.errAt(operand, msg, .{});
    return self.t().invalid_id;
}

/// A return type `e?` can leave with `none`: `T?`, or `T?!`.
pub fn returnsOptional(self: *Checker, ret: TypeId) bool {
    if (self.isPoison(ret)) return true;
    return switch (self.ctx.types.get(ret)) {
        .optional => true,
        .fallible => |inner| self.ctx.types.get(inner.ok) == .optional,
        else => false,
    };
}

/// The operand of `!` or `catch`, where a fallible call is handled.
pub fn synthHandled(self: *Checker, operand: Sexp) Error!TypeId {
    const prev = self.handled;
    defer self.handled = prev;
    self.handled = operand;
    return PatternCheck.synthExpr(self, operand);
}

/// `?x` / `!x`. A view of a view passes it on rather than
/// nesting (`?b` with `b: ?B` is `?B`). What `!x` puts on `x` is
/// recorded where its view is chosen (`recordLoan`).
pub fn synthView(self: *Checker, e: Sexp, kind: Checker.ViewKind) Error!TypeId {
    const view = try ViewCheck.makeViewOf(self, e, kind);
    if (kind == .write and !self.isPoison(view)) try ViewCheck.recordLoan(self, e, view);
    return view;
}
