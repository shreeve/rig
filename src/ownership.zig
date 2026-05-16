//! Rig Ownership Checker (M2).
//!
//! Walks the normalized semantic IR from `rig.Parser` and enforces
//! SPEC §"Ownership Checker V1" rules:
//!
//!   1. Use after move           (must error)
//!   2. Write while read borrowed (must error)
//!   3. Read while write borrowed (must error)
//!   4. Use after drop            (must error)
//!   5. Explicit shadow           (must allow)
//!   6. Fixed binding reassignment (must error)
//!   7. Borrow escape             (must error)
//!
//! V1 conservatism (per SPEC):
//!   - Path borrows lock the whole root binding.
//!   - Temporary (un-bound) borrows end at statement-end.
//!   - Bound borrows live until scope exit OR explicit drop of the binder.
//!   - Branches (if/while/match) merge conservatively: moved/dropped in any
//!     branch ⇒ invalid after.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const BindingKind = rig.BindingKind;

pub const Severity = enum { @"error", note };

pub const Diagnostic = struct {
    severity: Severity,
    pos: u32,
    message: []const u8,
};

pub const State = enum { valid, moved, dropped };

pub const Binding = struct {
    name: []const u8,
    state: State = .valid,
    fixed: bool = false,
    is_param: bool = false,
    borrowed_param: bool = false, // SPEC borrow-escape: was the param's type a `?T`?
    read_borrows: u16 = 0,
    write_borrows: u16 = 0,
    declared_at: u32, // source pos of binding
    moved_at: u32 = 0,
    dropped_at: u32 = 0,
    write_borrowed_at: u32 = 0,
    read_borrowed_at: u32 = 0,

    /// For each *bound* borrow `r = ?user`, we record which root binding
    /// `r` references so that scope-exit / `r`'s drop can release it.
    borrow_root_index: ?usize = null,
    borrow_kind: enum { none, read, write } = .none,
};

const Scope = struct {
    bindings: std.ArrayListUnmanaged(usize), // indices into Checker.bindings
    parent: ?usize, // index into Checker.scopes
};

/// Per-binding snapshot used by `walkIf`'s branch snapshot/merge. Only
/// captures fields that branches can mutate (state, borrow counts, and
/// the source positions that drive diagnostics for those mutations).
/// Identity / scope membership / borrow_root_index are stable across
/// branches, so they're not snapshotted.
const BindingSnapshot = struct {
    state: State,
    moved_at: u32,
    dropped_at: u32,
    read_borrows: u16,
    write_borrows: u16,
    read_borrowed_at: u32,
    write_borrowed_at: u32,
};

pub const Error = std.mem.Allocator.Error || rig.BindingKindError;

pub const Checker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    current_scope: usize = 0,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    /// True while inside a function body whose return type starts with an
    /// outer `(borrow_read ...)` or `(borrow_write ...)` — explicitly a
    /// borrowed return for SPEC's borrow-escape rule.
    in_borrowed_fn: bool = false,

    /// Optional sema context (M5(5/n)). When provided, `checkPlainUse`
    /// classifies the binding's type as Copy or Move and skips the
    /// move/drop/write-borrow checks for Copy types — matching SPEC's
    /// "Copy values can be used freely after a `move`" semantics.
    /// Without sema, the conservative M4.5 rules apply to all bindings.
    sema: ?*const types.SemContext = null,

    /// Per-statement temporary borrow events. Each (binding_idx, kind)
    /// is incremented during walk and decremented at statement end.
    /// Bound borrows (RHS of `(set name (read X))`) are claimed by
    /// `walkSet`/`walkBind` and never end up in this list.
    temp_borrows: std.ArrayListUnmanaged(TempBorrow) = .empty,

    const TempBorrow = struct {
        binding_idx: usize,
        kind: enum { read, write },
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Checker {
        var c = Checker{ .allocator = allocator, .source = source };
        try c.scopes.append(allocator, .{
            .bindings = .empty,
            .parent = null,
        });
        return c;
    }

    /// Constructor that wires the sema context. Use this from the CLI
    /// pipeline so `checkPlainUse` can classify Copy vs Move types via
    /// sema's symbol/type table.
    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, sema: *const types.SemContext) Error!Checker {
        var c = try init(allocator, source);
        c.sema = sema;
        return c;
    }

    pub fn deinit(self: *Checker) void {
        for (self.scopes.items) |*s| s.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        for (self.diagnostics.items) |d| self.allocator.free(d.message);
        self.diagnostics.deinit(self.allocator);
        self.temp_borrows.deinit(self.allocator);
    }

    pub fn check(self: *Checker, sexp: Sexp) Error!void {
        try self.walk(sexp, true);
    }

    pub fn hasErrors(self: *const Checker) bool {
        for (self.diagnostics.items) |d| if (d.severity == .@"error") return true;
        return false;
    }

    // -------------------------------------------------------------------------
    // Diagnostics
    // -------------------------------------------------------------------------

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = pos, .message = msg });
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .note, .pos = pos, .message = msg });
    }

    pub fn writeDiagnostics(self: *const Checker, file_path: []const u8, w: anytype) !void {
        for (self.diagnostics.items) |d| {
            const lc = lineCol(self.source, d.pos);
            const tag = switch (d.severity) {
                .@"error" => "error",
                .note => "  note",
            };
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, lc.line, lc.col, tag, d.message });
        }
    }

    // -------------------------------------------------------------------------
    // Scope management
    // -------------------------------------------------------------------------

    fn pushScope(self: *Checker) Error!void {
        const parent = self.current_scope;
        try self.scopes.append(self.allocator, .{
            .bindings = .empty,
            .parent = parent,
        });
        self.current_scope = self.scopes.items.len - 1;
    }

    fn popScope(self: *Checker) Error!void {
        // Release any bound-borrow aliases owned by this scope.
        const scope = &self.scopes.items[self.current_scope];
        for (scope.bindings.items) |bi| {
            self.releaseOwnedBorrow(bi);
        }
        if (scope.parent) |p| self.current_scope = p;
    }

    /// Release the borrow that `binding_idx` holds on its root, if any.
    /// Decrements the root's read/write counter, then clears
    /// `borrow_root_index` and `borrow_kind` on the holder so subsequent
    /// scope-pop / reassignment / drop don't double-release.
    ///
    /// Called from `popScope`, `walkDrop`, and `reassignOrBindFresh` —
    /// any path that ends or replaces the binding's lifetime.
    fn releaseOwnedBorrow(self: *Checker, binding_idx: usize) void {
        const b = &self.bindings.items[binding_idx];
        const ri = b.borrow_root_index orelse return;
        const root = &self.bindings.items[ri];
        switch (b.borrow_kind) {
            .read => if (root.read_borrows > 0) {
                root.read_borrows -= 1;
            },
            .write => if (root.write_borrows > 0) {
                root.write_borrows -= 1;
            },
            .none => {},
        }
        b.borrow_root_index = null;
        b.borrow_kind = .none;
    }

    /// Look up a binding by name, walking parent scopes.
    fn lookup(self: *Checker, name: []const u8) ?usize {
        var sid: ?usize = self.current_scope;
        while (sid) |s| {
            const scope = &self.scopes.items[s];
            // Reverse-order so explicit shadowing (`new x = ...`) finds
            // the freshest binding, not the original. Insertion-order
            // (forward) was a bug — it returned the OLD `x` after
            // `new x` and disagreed with the emitter (which does scan
            // reverse). Same correction applied to `lookupCurrent` below.
            var i = scope.bindings.items.len;
            while (i > 0) {
                i -= 1;
                const bi = scope.bindings.items[i];
                const b = &self.bindings.items[bi];
                if (std.mem.eql(u8, b.name, name)) return bi;
            }
            sid = scope.parent;
        }
        return null;
    }

    /// Look up a binding only in the current scope (for shadow legality).
    fn lookupCurrent(self: *Checker, name: []const u8) ?usize {
        const scope = &self.scopes.items[self.current_scope];
        var i = scope.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const bi = scope.bindings.items[i];
            const b = &self.bindings.items[bi];
            if (std.mem.eql(u8, b.name, name)) return bi;
        }
        return null;
    }

    fn addBinding(self: *Checker, b: Binding) Error!usize {
        const idx = self.bindings.items.len;
        try self.bindings.append(self.allocator, b);
        try self.scopes.items[self.current_scope].bindings.append(self.allocator, idx);
        return idx;
    }

    // -------------------------------------------------------------------------
    // Walk
    // -------------------------------------------------------------------------

    fn walk(self: *Checker, sexp: Sexp, is_stmt: bool) Error!void {
        // Plain `.src` reference at expression position. Without this,
        // moved/dropped values were happily readable via bare `print x`
        // (the silent-bug we're paying down). Field/binding-name `.src`
        // nodes never reach here because their parent forms (kwarg,
        // member, set, etc.) skip them in dedicated arms below.
        if (sexp == .src) {
            try self.checkPlainUse(sexp.src.pos, self.source[sexp.src.pos..][0..sexp.src.len]);
            return;
        }
        if (sexp != .list) return;
        const items = sexp.list;
        if (items.len == 0 or items[0] != .tag) return;

        const head = items[0].tag;
        switch (head) {
            .@"module" => for (items[1..]) |child| try self.walk(child, true),
            .@"fun", .@"sub" => try self.walkFun(items, head == .@"sub"),
            .@"lambda" => try self.walkFun(items, true), // sub-like for ownership
            .@"pub", .@"extern", .@"export", .@"packed", .@"callconv" => {
                if (items.len >= 2) try self.walk(items[items.len - 1], true);
            },
            .@"block" => try self.walkBlock(items[1..]),
            .@"set" => try self.walkSet(items),
            .@"drop" => try self.walkDrop(items),
            .@"move" => try self.walkBorrow(items, .move_op),
            .@"read" => try self.walkBorrow(items, .read_op),
            .@"write" => try self.walkBorrow(items, .write_op),
            .@"clone", .@"share", .@"weak", .@"pin", .@"raw" => {
                if (items.len >= 2) try self.walk(items[1], false);
            },
            .@"if" => try self.walkIf(items),
            .@"while" => try self.walkWhile(items),
            .@"for" => try self.walkFor(items),
            .@"match" => {
                if (items.len >= 2) try self.walk(items[1], false);
                for (items[2..]) |arm| {
                    try self.pushScope();
                    try self.walk(arm, true);
                    try self.popScope();
                }
            },
            .@"arm" => {
                // (arm pattern binding? body)
                if (items.len >= 2) try self.walk(items[items.len - 1], true);
            },
            .@"return" => try self.walkReturn(items),
            .@"try_block" => try self.walkTryBlock(items),
            .@"catch_block" => {
                // (catch_block name body) — the catch block has its own scope
                // Body is items[2]
                if (items.len >= 3) {
                    try self.pushScope();
                    // bind err name as a fresh binding
                    if (items[1] == .src) {
                        const nm = self.source[items[1].src.pos..][0..items[1].src.len];
                        _ = try self.addBinding(.{ .name = nm, .declared_at = items[1].src.pos });
                    }
                    try self.walk(items[2], true);
                    try self.popScope();
                }
            },
            .@"propagate" => {
                if (items.len >= 2) try self.walk(items[1], false);
            },
            .@"call" => try self.walkCall(items),
            .@"member" => {
                // (member obj name) — only `obj` is a value reference;
                // `name` is a literal field selector, never a binding use.
                if (items.len >= 2) try self.walk(items[1], false);
            },
            .@"kwarg" => {
                // (kwarg name value) — name is a literal field selector
                // for keyword args / record fields. Only walk the value.
                if (items.len >= 3) try self.walk(items[2], false);
            },
            // Identifier-bearing constructs whose name child is NOT a
            // value use of a binding — skip walking children entirely
            // so we don't trip checkPlainUse on a literal name.
            .@"enum_lit", .@"use", .@"type", .@"generic_type",
            .@"struct", .@"enum", .@"errors", .@"opaque",
            => {},
            .@"record" => {
                // (record TypeName members...) — TypeName is a type
                // reference, never a value binding; walk only members.
                for (items[2..]) |child| try self.walk(child, false);
            },
            else => {
                // Generic: walk all children as expressions. `.src` children
                // hit the top-of-walk arm above, which runs the plain-use
                // check.
                for (items[1..]) |child| try self.walk(child, false);
            },
        }
        _ = is_stmt;
    }

    /// Plain (non-sigil) value-use check.
    ///
    /// M4.5 stance (defer Copy/Move semantics to M5 type checker):
    ///   - if the binding has been moved → error
    ///   - if the binding has been dropped → error
    ///   - if a write borrow is currently live → error (write-borrow
    ///     exclusivity is already promised by SPEC; concurrent reads of
    ///     any kind violate it)
    ///   - otherwise no-op (no borrow count change, no lifetime effect)
    ///
    /// Names that don't resolve in any visible scope (function names,
    /// type names, builtins like `print`) are ignored — those aren't
    /// in the binding table.
    fn checkPlainUse(self: *Checker, pos: u32, name: []const u8) Error!void {
        const idx = self.lookup(name) orelse return;
        const b = &self.bindings.items[idx];

        // M5(5/n): if sema can classify this binding's type as Copy
        // (Bool, Int, Float, String, etc.), plain uses are unconditionally
        // OK — Copy values can be freely re-used after a "move", because
        // the move was really a copy. Only Move types (nominal user
        // types, optional/fallible/borrow wrappers, etc.) are subject
        // to the move/drop/write-borrow restrictions.
        //
        // Without sema (unit-test paths), every binding is treated as
        // Move — preserving the conservative M4.5 rules.
        if (self.semaBindingIsCopy(b)) return;

        if (b.state == .moved) {
            try self.err(pos, "use of `{s}` after move", .{name});
            try self.note(b.moved_at, "`{s}` was moved here", .{name});
            return;
        }
        if (b.state == .dropped) {
            try self.err(pos, "use of `{s}` after drop", .{name});
            try self.note(b.dropped_at, "`{s}` was dropped here", .{name});
            return;
        }
        if (b.write_borrows > 0) {
            try self.err(pos, "use of `{s}` while a write borrow is live", .{name});
            try self.note(b.write_borrowed_at, "write borrow taken here", .{});
            return;
        }
    }

    /// Classify the binding's sema-side type as Copy vs Move. Returns
    /// false if sema isn't wired or the binding can't be located.
    ///
    /// Copy types in M5 v1: Bool, Int (any size), Float (any size),
    /// String, and the literal pseudo-types. Everything else (nominal
    /// user types, optional/fallible/borrow wrappers, slice, array,
    /// function, unknown, invalid) defaults to Move so existing
    /// move/drop/borrow tests keep firing where they did before.
    ///
    /// The lookup is by `(name, declared_at)` — declared_at is unique
    /// per binding instance so this works under shadowing. O(N) over
    /// sema.symbols; fine for M5 v1.
    fn semaBindingIsCopy(self: *Checker, b: *const Binding) bool {
        const sema = self.sema orelse return false;
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos == b.declared_at and std.mem.eql(u8, sym.name, b.name)) {
                return isCopyType(sema, sym.ty);
            }
        }
        return false;
    }

    fn walkBlock(self: *Checker, stmts: []const Sexp) Error!void {
        try self.pushScope();
        for (stmts) |s| {
            try self.walkStmt(s);
        }
        try self.popScope();
    }

    /// Walk one statement, then release any temporary borrows incurred by it.
    /// (SPEC §"Borrow Lifetime": temporary borrows end at statement end.)
    fn walkStmt(self: *Checker, stmt: Sexp) Error!void {
        const before = self.temp_borrows.items.len;
        try self.walk(stmt, true);
        // Release temp borrows opened during this statement.
        while (self.temp_borrows.items.len > before) {
            const tb = self.temp_borrows.pop().?;
            const b = &self.bindings.items[tb.binding_idx];
            switch (tb.kind) {
                .read => if (b.read_borrows > 0) {
                    b.read_borrows -= 1;
                },
                .write => if (b.write_borrows > 0) {
                    b.write_borrows -= 1;
                },
            }
        }
    }

    fn walkFun(self: *Checker, items: []const Sexp, is_sub: bool) Error!void {
        // (fun name params returns body) or (sub name params body)
        const params = if (items.len > 2) items[2] else Sexp{ .nil = {} };
        const returns: Sexp = if (!is_sub and items.len > 3) items[3] else Sexp{ .nil = {} };
        const body = items[items.len - 1];

        const prev_borrowed = self.in_borrowed_fn;
        self.in_borrowed_fn = isBorrowedReturn(returns);

        try self.pushScope();
        // Bind parameters
        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }

        // Walk body. If body is a `(block ...)`, we inline the walk here so
        // we can run the borrow-escape check on the last (implicit-return)
        // statement WHILE the block's scope is still live.
        if (body == .list and body.list.len > 0 and body.list[0] == .tag and
            body.list[0].tag == .@"block")
        {
            const stmts = body.list[1..];
            try self.pushScope();
            for (stmts, 0..) |stmt, i| {
                try self.walkStmt(stmt);
                if (i == stmts.len - 1 and self.in_borrowed_fn) {
                    try self.checkBorrowEscape(stmt);
                }
            }
            try self.popScope();
        } else {
            try self.walkStmt(body);
        }

        try self.popScope();
        self.in_borrowed_fn = prev_borrowed;
    }

    fn bindParam(self: *Checker, p: Sexp) Error!void {
        // Param shapes:
        //   name                                — untyped
        //   (: name type)                       — typed
        //   (pre_param name type)               — comptime-typed
        //   (default name type expr)            — typed with default
        //   (aligned name type alignexpr)       — typed with align
        //   (read NAME) / (write NAME)          — M20a.1 `?self` / `!self` sugar
        var name_node: Sexp = Sexp{ .nil = {} };
        var type_node: Sexp = Sexp{ .nil = {} };
        var sugar_borrowed = false;
        switch (p) {
            .src => name_node = p,
            .list => {
                if (p.list.len >= 2 and p.list[0] == .tag) {
                    switch (p.list[0].tag) {
                        .@":", .pre_param, .default, .aligned => {
                            name_node = p.list[1];
                            if (p.list.len >= 3) type_node = p.list[2];
                        },
                        // M20a.1: `?self` / `!self` sugar appears as
                        // `(read NAME)` / `(write NAME)` at param
                        // position. The sema-side resolveParamType
                        // synthesizes the borrow type; here we just
                        // need to bind the name as a borrowed param so
                        // ownership analysis applies the right rules.
                        // M20a.2 (per GPT-5.5 pre-commit review): guard
                        // against malformed `(read)` / `(write)` Sexp
                        // (grammar guarantees len >= 2, but a defensive
                        // bound check costs nothing).
                        .@"read", .@"write" => {
                            if (p.list.len >= 2) {
                                name_node = p.list[1];
                                sugar_borrowed = true;
                            }
                        },
                        else => {},
                    }
                } else if (p.list.len >= 1) {
                    name_node = p.list[0];
                }
            },
            else => return,
        }
        if (name_node != .src) return;
        const nm = self.source[name_node.src.pos..][0..name_node.src.len];
        const borrowed = sugar_borrowed or isBorrowedType(type_node);
        _ = try self.addBinding(.{
            .name = nm,
            .is_param = true,
            .borrowed_param = borrowed,
            .declared_at = name_node.src.pos,
        });
    }

    /// Universal binding walker. Decodes the kind slot of `(set <kind> ...)`
    /// into the exhaustive `BindingKind` enum and dispatches via a switch
    /// that the Zig compiler enforces to be exhaustive — adding a new
    /// `BindingKind` variant breaks the build until this function handles it.
    fn walkSet(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 5) return;
        const kind = try rig.bindingKindOf(items[1]);
        const target = items[2];
        const expr = items[4];

        // M20d alias-footgun rule: bare `*T` / `~T` on the RHS of an
        // ordinary `=` would compile to `const rc2 = rc;` in Zig — a
        // pointer copy without a refcount bump, leaving two Rig
        // bindings owning the same RcBox. Per GPT-5.5's M20d post-(1/5)
        // review: this is THE biggest M20d footgun after auto-drop.
        // Require explicit `<rc` (move) or `+rc` (clone) so the
        // ownership transfer or refcount bump is visible at the call
        // site, matching Rig's visible-effects thesis.
        //
        // `<-` (move-assign, kind == .@"move") is already explicit at
        // the assignment-operator level, so it skips this check.
        // Compound `+=` / `-=` etc. on a handle type doesn't reach the
        // alias scenario meaningfully (the operation itself is ill-
        // defined for handles); leave the existing type-checker to
        // complain there.
        if (kind == .default or kind == .fixed or kind == .shadow) try self.checkSharedHandleAlias(expr, "binding");

        // RHS effects first.
        try self.walk(expr, false);

        // For `<-` move-assign, the target receives the moved value — we
        // must also mark the source as moved. Synthesize a (move <expr>)
        // walk so the borrow checker observes the move on the source name.
        if (kind == .@"move") {
            const move_wrap = [_]Sexp{ .{ .tag = .@"move" }, expr };
            try self.walkBorrow(&move_wrap, .move_op);
        }

        const target_name = identName(self.source, target) orelse {
            try self.walk(target, false);
            return;
        };
        const nm = target_name;
        const target_pos: u32 = if (target == .src) target.src.pos else 0;

        switch (kind) {
            .shadow => try self.bindFreshAlways(nm, target_pos, false, expr),
            .fixed => try self.bindFreshNoCollide(nm, target_pos, true, expr),
            .default, .@"move" => try self.reassignOrBindFresh(nm, target_pos, expr, false),
            .@"+=", .@"-=", .@"*=", .@"/=" => try self.reassignOrBindFresh(nm, target_pos, expr, true),
        }
        // No `else` — exhaustive on BindingKind. Adding a new kind to
        // rig.BindingKind will break this build until we handle it here.
    }

    /// Always create a fresh binding in the current scope (for `shadow`).
    fn bindFreshAlways(self: *Checker, nm: []const u8, pos: u32, fixed: bool, expr: Sexp) Error!void {
        const idx = try self.addBinding(.{
            .name = nm,
            .fixed = fixed,
            .declared_at = pos,
        });
        self.maybeRecordBoundBorrow(idx, expr);
    }

    /// Create a fresh binding, erroring if the name already exists in the
    /// current (innermost) scope (for `fixed`).
    fn bindFreshNoCollide(self: *Checker, nm: []const u8, pos: u32, fixed: bool, expr: Sexp) Error!void {
        if (self.lookupCurrent(nm)) |bi| {
            const b = &self.bindings.items[bi];
            try self.err(pos, "binding `{s}` already exists in this scope", .{nm});
            try self.note(b.declared_at, "previous binding here", .{});
            return;
        }
        try self.bindFreshAlways(nm, pos, fixed, expr);
    }

    /// If the name resolves in any visible scope, reassign it (with the
    /// usual fixed/moved/borrow checks). Otherwise create a fresh binding
    /// — unless `is_compound`, in which case compound-on-undefined errors.
    fn reassignOrBindFresh(self: *Checker, nm: []const u8, pos: u32, expr: Sexp, is_compound: bool) Error!void {
        if (self.lookup(nm)) |bi| {
            const b = &self.bindings.items[bi];
            if (b.fixed) {
                try self.err(pos, "cannot reassign fixed binding `{s}`", .{nm});
                try self.note(b.declared_at, "`{s}` was bound here with `=!`", .{nm});
                return;
            }
            if (b.state == .moved) {
                try self.err(pos, "cannot reassign `{s}` (would write to moved value)", .{nm});
                try self.note(b.moved_at, "`{s}` was moved here", .{nm});
                return;
            }
            if (b.read_borrows > 0 or b.write_borrows > 0) {
                try self.err(pos, "cannot reassign `{s}` while borrows are live", .{nm});
                return;
            }
            // Reassigning a binding that holds a borrow ends that borrow.
            // Without releasing here, `r = ?user; r = something_else`
            // would leak `user.read_borrows = 1` forever.
            self.releaseOwnedBorrow(bi);
            b.state = .valid;
            self.maybeRecordBoundBorrow(bi, expr);
            return;
        }
        if (is_compound) {
            try self.err(pos, "compound assignment on undefined `{s}`", .{nm});
            return;
        }
        try self.bindFreshAlways(nm, pos, false, expr);
    }

    /// If `expr` is a borrow wrapper around a name (`(read X)` or `(write X)`),
    /// record on `binding_idx` that it aliases X's borrows AND claim the
    /// temp_borrow event so the borrow counter survives statement-end.
    /// The root.read_/write_borrows count then persists until binding_idx's
    /// scope exits (handled in `popScope`).
    fn maybeRecordBoundBorrow(self: *Checker, binding_idx: usize, expr: Sexp) void {
        if (expr != .list or expr.list.len < 2 or expr.list[0] != .tag) return;
        const t = expr.list[0].tag;
        const kind: @TypeOf(self.bindings.items[0].borrow_kind) = switch (t) {
            .@"read" => .read,
            .@"write" => .write,
            else => return,
        };
        const root = rootName(self.source, expr.list[1]) orelse return;
        const ri = self.lookup(root) orelse return;
        const bound = &self.bindings.items[binding_idx];
        bound.borrow_root_index = ri;
        bound.borrow_kind = kind;
        // Claim the most recent matching temp_borrow event: it should be the
        // one we just incremented when walking the RHS borrow.
        var i = self.temp_borrows.items.len;
        while (i > 0) {
            i -= 1;
            const tb = self.temp_borrows.items[i];
            if (tb.binding_idx == ri and ((tb.kind == .read and kind == .read) or
                (tb.kind == .write and kind == .write)))
            {
                _ = self.temp_borrows.orderedRemove(i);
                return;
            }
        }
    }

    const BorrowOp = enum { move_op, read_op, write_op };

    fn walkBorrow(self: *Checker, items: []const Sexp, op: BorrowOp) Error!void {
        if (items.len < 2) return;
        const inner = items[1];
        // Path resolution: `(read x)` or `(read (member x ...))` → root x
        const root_name = rootName(self.source, inner) orelse {
            // Borrow of a non-name expression — walk inner, no checks.
            try self.walk(inner, false);
            return;
        };
        const root_pos: u32 = innerPos(inner);
        const idx = self.lookup(root_name) orelse {
            try self.err(root_pos, "use of unbound name `{s}`", .{root_name});
            return;
        };
        const b = &self.bindings.items[idx];
        if (b.state == .moved) {
            try self.err(root_pos, "use of `{s}` after move", .{root_name});
            try self.note(b.moved_at, "`{s}` was moved here", .{root_name});
            return;
        }
        if (b.state == .dropped) {
            try self.err(root_pos, "use of `{s}` after drop", .{root_name});
            try self.note(b.dropped_at, "`{s}` was dropped here", .{root_name});
            return;
        }

        switch (op) {
            .move_op => {
                if (b.read_borrows > 0) {
                    try self.err(root_pos, "cannot move `{s}` while it is read-borrowed", .{root_name});
                    try self.note(b.read_borrowed_at, "read borrow taken here", .{});
                    return;
                }
                if (b.write_borrows > 0) {
                    try self.err(root_pos, "cannot move `{s}` while it is write-borrowed", .{root_name});
                    try self.note(b.write_borrowed_at, "write borrow taken here", .{});
                    return;
                }
                b.state = .moved;
                b.moved_at = root_pos;
            },
            .read_op => {
                if (b.write_borrows > 0) {
                    try self.err(root_pos, "cannot read-borrow `{s}` while a write borrow is live", .{root_name});
                    try self.note(b.write_borrowed_at, "write borrow taken here", .{});
                    return;
                }
                b.read_borrows += 1;
                if (b.read_borrows == 1) b.read_borrowed_at = root_pos;
                try self.temp_borrows.append(self.allocator, .{ .binding_idx = idx, .kind = .read });
            },
            .write_op => {
                if (b.read_borrows > 0) {
                    try self.err(root_pos, "cannot write-borrow `{s}` while a read borrow is live", .{root_name});
                    try self.note(b.read_borrowed_at, "read borrow taken here", .{});
                    return;
                }
                if (b.write_borrows > 0) {
                    try self.err(root_pos, "cannot take a second write borrow on `{s}`", .{root_name});
                    try self.note(b.write_borrowed_at, "first write borrow taken here", .{});
                    return;
                }
                b.write_borrows += 1;
                b.write_borrowed_at = root_pos;
                try self.temp_borrows.append(self.allocator, .{ .binding_idx = idx, .kind = .write });
            },
        }
    }

    fn walkDrop(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const target = items[1];
        if (target != .src) return;
        const nm = self.source[target.src.pos..][0..target.src.len];
        const idx = self.lookup(nm) orelse {
            try self.err(target.src.pos, "cannot drop unbound name `{s}`", .{nm});
            return;
        };
        const b = &self.bindings.items[idx];
        if (b.state == .moved) {
            try self.err(target.src.pos, "cannot drop `{s}` after it was moved", .{nm});
            try self.note(b.moved_at, "`{s}` was moved here", .{nm});
            return;
        }
        if (b.state == .dropped) {
            try self.err(target.src.pos, "cannot drop `{s}` twice", .{nm});
            try self.note(b.dropped_at, "first dropped here", .{});
            return;
        }
        if (b.read_borrows > 0 or b.write_borrows > 0) {
            try self.err(target.src.pos, "cannot drop `{s}` while borrows are live", .{nm});
            return;
        }
        // If `b` itself owns a borrow (`r = ?user; -r`), releasing it now
        // unlocks the root binding for further use. Without this, dropping
        // a borrow alias leaks the underlying read/write counter forever.
        self.releaseOwnedBorrow(idx);
        b.state = .dropped;
        b.dropped_at = target.src.pos;
    }

    fn walkCall(self: *Checker, items: []const Sexp) Error!void {
        // (call fn args...). Walk fn, walk each arg.
        //
        // M20d alias-footgun rule (parallel to walkSet): bare `*T`/`~T`
        // as a call argument would Zig-copy the pointer without a
        // refcount bump, silently leaving the caller and callee both
        // owning the same RcBox. Require explicit `<rc` (move into the
        // callee) or `+rc` (clone for shared use). For each arg, the
        // first child (items[1]) is the callee; args start at items[2].
        if (items.len >= 3) {
            for (items[2..]) |arg| {
                // Skip kwarg wrappers (`(kwarg name expr)`) — the
                // contained expr is the actual value we'd care about,
                // and it gets checked via the inner walk.
                if (arg == .list and arg.list.len >= 3 and arg.list[0] == .tag and
                    arg.list[0].tag == .@"kwarg")
                {
                    try self.checkSharedHandleAlias(arg.list[2], "call argument");
                } else {
                    try self.checkSharedHandleAlias(arg, "call argument");
                }
            }
        }
        for (items[1..]) |child| try self.walk(child, false);
    }

    /// M20d: diagnose the bare-shared/weak alias footgun. Fires only
    /// when `expr` is a bare `.src` whose binding's sema-side type is
    /// `shared(_)` or `weak(_)`. Suggests `<x` (move) or `+x` (clone) —
    /// both forms make the ownership/refcount effect visible at the
    /// call site, per Rig's visible-effects thesis.
    ///
    /// Silent on:
    ///   - non-name expressions (already wrapped or compound)
    ///   - bindings whose type isn't shared/weak
    ///   - no-sema mode (unit tests)
    /// so the check only fires when we're confident about the type.
    ///
    /// M20d.1 (per GPT-5.5's post-M20d review): uses the Checker's
    /// scope-aware `lookup` to find the binding in the current scope
    /// chain, then bridges to sema via `(name, declared_at)`. The
    /// earlier implementation did a flat `sema.symbols` scan which
    /// fires on the wrong binding under shadowing (e.g., a parameter
    /// named `rc` in one function with type `*Box`, another function
    /// with `rc: Int` — the flat scan finds the `*Box` first and
    /// mis-classifies the Int binding as shared). The shadowing
    /// regression test `examples/shared_alias_shadowing.rig` pins
    /// the correct behavior.
    fn checkSharedHandleAlias(self: *Checker, expr: Sexp, ctx: []const u8) Error!void {
        if (expr != .src) return;
        const sema = self.sema orelse return;
        const name = self.source[expr.src.pos..][0..expr.src.len];

        const idx = self.lookup(name) orelse return;
        const b = &self.bindings.items[idx];
        // Bridge to sema via (name, declared_at) — same pattern as
        // `semaBindingIsCopy`. Only one sema Symbol has this exact
        // pair, so first-match here is correct under shadowing.
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != b.declared_at) continue;
            if (!std.mem.eql(u8, sym.name, b.name)) continue;
            const ty = sema.types.get(sym.ty);
            const kind: ?[]const u8 = switch (ty) {
                .shared => "shared (`*T`)",
                .weak => "weak (`~T`)",
                else => null,
            };
            const handle_kind = kind orelse return;
            try self.err(expr.src.pos, "bare use of {s} handle `{s}` in {s} would alias the handle; use `<{s}` to move or `+{s}` to clone", .{
                handle_kind, name, ctx, name, name,
            });
            return;
        }
    }

    fn walkReturn(self: *Checker, items: []const Sexp) Error!void {
        // (return value? if?). Check borrow-escape on the value if borrowed-fn.
        if (items.len >= 2) {
            const value = items[1];
            try self.walk(value, false);
            if (self.in_borrowed_fn) try self.checkBorrowEscape(value);
        }
    }

    fn walkIf(self: *Checker, items: []const Sexp) Error!void {
        // (if cond then else?). Snapshot/merge so:
        //   if cond
        //     send <x
        //   else
        //     print ?x
        // doesn't falsely fire the else branch on `<x` (sequential walk
        // would have moved `x` before reaching the else). Each branch
        // walks against a fresh copy of the binding state; afterwards we
        // merge with conservative semantics:
        //
        //   - State: dropped beats moved beats valid (priority order
        //     matches user intent — explicit `-x` is more authored than
        //     consumed-by-move). Diagnostic positions follow the winner.
        //   - Borrow counts: max() per kind. Only one branch executes,
        //     so summing would over-count.
        //
        // Branch-local borrow bindings are released by `popScope` before
        // we capture state, so phantom borrows don't bleed into the merge.
        if (items.len < 2) return;

        // 1. Walk condition on the current state.
        try self.walk(items[1], false);

        const have_else = items.len >= 4;
        const then_branch = if (items.len >= 3) items[2] else return;

        // 2. Snapshot before walking either branch.
        var base_snapshot = try self.snapshotBindings();
        defer base_snapshot.deinit(self.allocator);

        // 3. Walk THEN branch in its own scope.
        try self.pushScope();
        try self.walk(then_branch, true);
        try self.popScope();
        var then_snapshot = try self.snapshotBindings();
        defer then_snapshot.deinit(self.allocator);

        // 4. Restore base, walk ELSE branch (or use base as the else snapshot).
        self.restoreBindings(base_snapshot.items);
        if (have_else) {
            try self.pushScope();
            try self.walk(items[3], true);
            try self.popScope();
        }
        var else_snapshot = try self.snapshotBindings();
        defer else_snapshot.deinit(self.allocator);

        // 5. Merge then/else into the current state.
        self.mergeBindings(then_snapshot.items, else_snapshot.items);
    }

    /// Per-binding state snapshot for branch merging. Caller owns the
    /// returned slice and must deinit it.
    fn snapshotBindings(self: *Checker) Error!std.ArrayListUnmanaged(BindingSnapshot) {
        var out: std.ArrayListUnmanaged(BindingSnapshot) = .empty;
        try out.ensureTotalCapacity(self.allocator, self.bindings.items.len);
        for (self.bindings.items) |b| {
            out.appendAssumeCapacity(.{
                .state = b.state,
                .moved_at = b.moved_at,
                .dropped_at = b.dropped_at,
                .read_borrows = b.read_borrows,
                .write_borrows = b.write_borrows,
                .read_borrowed_at = b.read_borrowed_at,
                .write_borrowed_at = b.write_borrowed_at,
            });
        }
        return out;
    }

    fn restoreBindings(self: *Checker, snap: []const BindingSnapshot) void {
        // Snapshots cover the prefix of bindings that existed at snapshot
        // time. New bindings created inside a branch were freed by
        // popScope (their scope was popped) and so don't survive into
        // the post-branch state — but they ARE still in `self.bindings`
        // (we don't free that table). Just restore the prefix.
        const n = @min(snap.len, self.bindings.items.len);
        for (snap[0..n], 0..) |s, i| {
            const b = &self.bindings.items[i];
            b.state = s.state;
            b.moved_at = s.moved_at;
            b.dropped_at = s.dropped_at;
            b.read_borrows = s.read_borrows;
            b.write_borrows = s.write_borrows;
            b.read_borrowed_at = s.read_borrowed_at;
            b.write_borrowed_at = s.write_borrowed_at;
        }
    }

    fn mergeBindings(self: *Checker, then_snap: []const BindingSnapshot, else_snap: []const BindingSnapshot) void {
        const n = @min(@min(then_snap.len, else_snap.len), self.bindings.items.len);
        for (0..n) |i| {
            const b = &self.bindings.items[i];
            const t = then_snap[i];
            const e = else_snap[i];

            // State: dropped > moved > valid.
            const merged_state: State = if (t.state == .dropped or e.state == .dropped)
                .dropped
            else if (t.state == .moved or e.state == .moved)
                .moved
            else
                .valid;
            b.state = merged_state;
            // Carry the position from the branch that produced the winning state.
            switch (merged_state) {
                .dropped => b.dropped_at = if (t.state == .dropped) t.dropped_at else e.dropped_at,
                .moved => b.moved_at = if (t.state == .moved) t.moved_at else e.moved_at,
                .valid => {},
            }

            // Borrow counts: max (only one branch actually executes).
            b.read_borrows = @max(t.read_borrows, e.read_borrows);
            b.write_borrows = @max(t.write_borrows, e.write_borrows);
            b.read_borrowed_at = if (t.read_borrows >= e.read_borrows) t.read_borrowed_at else e.read_borrowed_at;
            b.write_borrowed_at = if (t.write_borrows >= e.write_borrows) t.write_borrowed_at else e.write_borrowed_at;
        }
    }

    fn walkWhile(self: *Checker, items: []const Sexp) Error!void {
        for (items[1..]) |child| try self.walk(child, false);
    }

    fn walkFor(self: *Checker, items: []const Sexp) Error!void {
        // Unified shape (set by `Parser.normFor`):
        //   (for <mode> binding1 binding2-or-_ source body else?)
        //
        // For ownership purposes the body sees `binding1` (and `binding2`
        // if present) as fresh locals. The source's mode tag is
        // informational for V1; we conservatively just walk the source as
        // an expression and rely on the loop-body's borrow rules.
        if (items.len < 6) return;
        const binding1 = items[2];
        const binding2 = items[3];
        const source = items[4];
        const body = items[5];

        try self.walk(source, false);
        try self.pushScope();
        if (binding1 == .src) {
            const nm = self.source[binding1.src.pos..][0..binding1.src.len];
            _ = try self.addBinding(.{
                .name = nm,
                .declared_at = binding1.src.pos,
            });
        }
        if (binding2 == .src) {
            const nm = self.source[binding2.src.pos..][0..binding2.src.len];
            _ = try self.addBinding(.{
                .name = nm,
                .declared_at = binding2.src.pos,
            });
        }
        try self.walk(body, true);
        try self.popScope();
        if (items.len > 6) try self.walk(items[6], true);
    }

    fn walkTryBlock(self: *Checker, items: []const Sexp) Error!void {
        if (items.len >= 2) try self.walk(items[1], true);
        if (items.len >= 3) try self.walk(items[2], true);
    }

    /// SPEC borrow-escape: any `(read X)` / `(write X)` reachable from
    /// the return expression must root in a borrowed parameter.
    ///
    /// Walks the entire return-expression subtree so nested cases like
    /// `View(?user)` (call arg), `if cond ?local else ?param` (branch
    /// arm), and `record T (kwarg n ?user)` (constructor field) all
    /// fire — earlier versions only inspected the top-level form, which
    /// silently missed every nested case.
    ///
    /// Diagnostics dedupe per root binding so a single `View(?u, ?u, ?u)`
    /// produces one error, not three. Recurses into all children except
    /// nested `(fun ...)` / `(sub ...)` / `(lambda ...)` (those have
    /// their own return-escape boundaries) and into binding-name slots
    /// (which aren't expressions).
    fn checkBorrowEscape(self: *Checker, value: Sexp) Error!void {
        var seen_roots: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_roots.deinit(self.allocator);
        try self.checkBorrowEscapeRec(value, &seen_roots);
    }

    fn checkBorrowEscapeRec(
        self: *Checker,
        value: Sexp,
        seen: *std.StringHashMapUnmanaged(void),
    ) Error!void {
        if (value != .list) return;
        const items = value.list;
        if (items.len == 0) return;
        if (items[0] != .tag) {
            for (items) |c| try self.checkBorrowEscapeRec(c, seen);
            return;
        }
        switch (items[0].tag) {
            // Don't cross function boundaries — nested fn/sub/lambda
            // have their own return-escape semantics handled separately.
            .@"fun", .@"sub", .@"lambda" => return,

            // Leaf: a borrow wrapper. Validate its root, then recurse
            // into the inner (in case there's another borrow nested,
            // e.g., `View(?(member u inner))` — pathological but cheap
            // to handle).
            .@"read", .@"write" => {
                if (items.len >= 2) {
                    const inner = items[1];
                    if (rootName(self.source, inner)) |root| {
                        if (!seen.contains(root)) {
                            try seen.put(self.allocator, root, {});
                            if (self.lookup(root)) |idx| {
                                const b = &self.bindings.items[idx];
                                if (!b.is_param or !b.borrowed_param) {
                                    try self.err(innerPos(inner), "returned borrow of `{s}` does not originate from a borrowed parameter", .{root});
                                    try self.note(b.declared_at, "`{s}` was bound locally here", .{root});
                                }
                            }
                        }
                    }
                    try self.checkBorrowEscapeRec(inner, seen);
                }
            },

            // Skip name slots that aren't value expressions.
            .@"set" => {
                // (set kind name type-or-_ expr) — only the expr can
                // contain returnable borrows.
                if (items.len >= 5) try self.checkBorrowEscapeRec(items[4], seen);
            },
            .@"member" => {
                // (member obj name) — obj only; name is a field selector.
                if (items.len >= 2) try self.checkBorrowEscapeRec(items[1], seen);
            },
            .@"kwarg" => {
                // (kwarg name value) — value only.
                if (items.len >= 3) try self.checkBorrowEscapeRec(items[2], seen);
            },

            // Default: recurse into all children.
            else => for (items[1..]) |c| try self.checkBorrowEscapeRec(c, seen),
        }
    }
};

// =============================================================================
// Helpers
// =============================================================================

fn identName(source: []const u8, sexp: Sexp) ?[]const u8 {
    return switch (sexp) {
        .src => |s| source[s.pos..][0..s.len],
        else => null,
    };
}

fn rootName(source: []const u8, sexp: Sexp) ?[]const u8 {
    switch (sexp) {
        .src => |s| return source[s.pos..][0..s.len],
        .list => |items| {
            if (items.len >= 2 and items[0] == .tag) {
                switch (items[0].tag) {
                    .@"member", .@"index", .@"deref" => return rootName(source, items[1]),
                    .@"read", .@"write", .@"move", .@"clone", .@"share", .@"weak", .@"pin", .@"raw" => return rootName(source, items[1]),
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

fn innerPos(sexp: Sexp) u32 {
    return switch (sexp) {
        .src => |s| s.pos,
        .list => |items| blk: {
            // Skip the leading .tag (which has no source pos) and recurse
            // into the first child that has one.
            for (items) |child| {
                const p = innerPos(child);
                if (p != 0) break :blk p;
            }
            break :blk 0;
        },
        else => 0,
    };
}

/// Is this return type a "borrowed" return (i.e., starts with `?` per SPEC's
/// borrow-escape example)? Now that Rig has explicit `(borrow_read T)` and
/// `(borrow_write T)` heads (from the prefix `?T` / `!T` syntax in type
/// position), we no longer need to use `(optional T)` as a heuristic — we
/// can check directly. `(optional T)` (from suffix `T?`) now correctly
/// means "the value may be missing" with no borrowing implication.
fn isBorrowedReturn(returns: Sexp) bool {
    return isBorrowedType(returns);
}

fn isBorrowedType(t: Sexp) bool {
    if (t != .list or t.list.len < 2 or t.list[0] != .tag) return false;
    return switch (t.list[0].tag) {
        .borrow_read, .borrow_write => true,
        else => false,
    };
}

/// M5 v1 Copy classification: which TypeIds are safe to use freely
/// after a move? Conservative: only primitives + literal pseudo-types.
/// Everything else (nominals, wrappers, slices, etc.) is Move.
fn isCopyType(sema: *const types.SemContext, ty_id: types.TypeId) bool {
    const ty = sema.types.get(ty_id);
    return switch (ty) {
        .bool, .int, .float, .string, .int_literal, .float_literal => true,
        else => false,
    };
}

const LineCol = struct { line: u32, col: u32 };

fn lineCol(source: []const u8, pos: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    const end = @min(pos, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

// =============================================================================
// Tests
// =============================================================================

/// Test helper. `parser.Parser` auto-wires to `rig.Parser`, which owns
/// its own arena for both the raw parse and the rewritten IR — so the
/// only resource the test caller has to clean up is the parser handle
/// itself (and the Checker, which holds diagnostics via `allocator`).
const TestRig = struct {
    parser_obj: parser.Parser,
    checker: Checker,

    fn deinit(self: *TestRig) void {
        self.checker.deinit();
        self.parser_obj.deinit();
    }
};

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !TestRig {
    var p = parser.Parser.init(allocator, source);
    errdefer p.deinit();
    const ir = try p.parseProgram();   // already rewritten by rig.Parser

    var c = try Checker.init(allocator, source);
    errdefer c.deinit();
    try c.check(ir);

    return .{ .parser_obj = p, .checker = c };
}

test "ownership: use after move errors" {
    const source =
        \\sub main()
        \\  packet = make_packet()
        \\  send <packet
        \\  log ?packet
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(t.checker.hasErrors());
}

test "ownership: hello passes" {
    const source =
        \\sub main()
        \\  print "hello"
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(!t.checker.hasErrors());
}

test "ownership: fixed binding reassign errors" {
    const source =
        \\sub main()
        \\  user =! make()
        \\  user = remake()
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(t.checker.hasErrors());
}

test "ownership: explicit shadow allowed" {
    const source =
        \\sub main()
        \\  x = 1
        \\  new x = 2
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(!t.checker.hasErrors());
}

test "ownership: temporary read borrow ends at statement end" {
    const source =
        \\sub main()
        \\  user = make_user()
        \\  print ?user
        \\  rename !user
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(!t.checker.hasErrors());
}

test "ownership: bound borrow blocks write" {
    const source =
        \\sub main()
        \\  user = make_user()
        \\  r = ?user
        \\  rename !user
        \\
    ;
    var t = try checkSource(std.testing.allocator, source);
    defer t.deinit();
    try std.testing.expect(t.checker.hasErrors());
}
