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

pub const Error = std.mem.Allocator.Error;

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
            const b = &self.bindings.items[bi];
            if (b.borrow_root_index) |ri| {
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
            }
        }
        if (scope.parent) |p| self.current_scope = p;
    }

    /// Look up a binding by name, walking parent scopes.
    fn lookup(self: *Checker, name: []const u8) ?usize {
        var sid: ?usize = self.current_scope;
        while (sid) |s| {
            const scope = &self.scopes.items[s];
            for (scope.bindings.items) |bi| {
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
        for (scope.bindings.items) |bi| {
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
                // (member obj name)
                if (items.len >= 2) try self.walk(items[1], false);
            },
            else => {
                // generic: walk all children as expressions
                for (items[1..]) |child| try self.walk(child, false);
            },
        }
        _ = is_stmt;
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
        // Param shapes: name | (: name type) | (pre_param name type) | (default name type expr) | (aligned name type alignexpr)
        var name_node: Sexp = Sexp{ .nil = {} };
        var type_node: Sexp = Sexp{ .nil = {} };
        switch (p) {
            .src => name_node = p,
            .list => {
                if (p.list.len >= 2 and p.list[0] == .tag) {
                    switch (p.list[0].tag) {
                        .@":", .pre_param, .default, .aligned => {
                            name_node = p.list[1];
                            if (p.list.len >= 3) type_node = p.list[2];
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
        const borrowed = isBorrowedType(type_node);
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
        const kind = rig.bindingKindOf(items[1]);
        const target = items[2];
        const expr = items[4];

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
        b.state = .dropped;
        b.dropped_at = target.src.pos;
    }

    fn walkCall(self: *Checker, items: []const Sexp) Error!void {
        // (call fn args...). Walk fn, walk each arg.
        for (items[1..]) |child| try self.walk(child, false);
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
        // (if cond then else?). Walk children; conservative no-merge for V1.
        for (items[1..]) |child| try self.walk(child, false);
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

    /// SPEC borrow-escape: any `(read X)` / `(write X)` etc. in the returned
    /// expression must root in a borrowed parameter (b.borrowed_param).
    fn checkBorrowEscape(self: *Checker, value: Sexp) Error!void {
        if (value != .list or value.list.len < 2 or value.list[0] != .tag) return;
        switch (value.list[0].tag) {
            .@"read", .@"write" => {
                const inner = value.list[1];
                const root = rootName(self.source, inner) orelse return;
                if (self.lookup(root)) |idx| {
                    const b = &self.bindings.items[idx];
                    if (!b.is_param or !b.borrowed_param) {
                        try self.err(innerPos(inner), "returned borrow of `{s}` does not originate from a borrowed parameter", .{root});
                        try self.note(b.declared_at, "`{s}` was bound locally here", .{root});
                    }
                }
            },
            else => {},
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
