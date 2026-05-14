//! Rig Semantic Normalizer (M1).
//!
//! Walks a raw S-expression tree from `parser.zig` and produces a
//! normalized semantic IR for the M2 ownership checker and the M3
//! Zig emitter.
//!
//! Source spans are preserved on every transformed node (the `.src`
//! variant of Sexp carries `pos`, `len`, and resolved `id`).
//!
//! See `docs/SEMANTIC-SEXP.md` for the full IR shape.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;

pub const Normalizer = struct {
    arena: *std.mem.Allocator,

    pub fn init(arena: *std.mem.Allocator) Normalizer {
        return .{ .arena = arena };
    }

    /// Normalize a parsed module.
    pub fn normalize(self: *Normalizer, sexp: Sexp) !Sexp {
        return self.walk(sexp);
    }

    // -------------------------------------------------------------------------
    // Tree walk
    // -------------------------------------------------------------------------

    fn walk(self: *Normalizer, sexp: Sexp) std.mem.Allocator.Error!Sexp {
        switch (sexp) {
            .nil, .tag, .src, .str => return sexp,
            .list => |items| {
                if (items.len == 0) return sexp;
                if (items[0] != .tag) return self.walkChildren(sexp);

                return switch (items[0].tag) {
                    .@"=" => try self.normSet(items),
                    .@"+=", .@"-=", .@"*=", .@"/=" => try self.normSetOp(items),
                    .@"move_assign" => try self.normMoveAssign(items),
                    .@"fixed_bind" => try self.normBindWithType(items, .fixed_bind, null),
                    .@"shadow" => try self.normBindWithType(items, .shadow, null),
                    .@"typed_assign" => try self.normTyped(items, .set),
                    .@"typed_fixed" => try self.normTyped(items, .fixed_bind),
                    .@"extern_var" => try self.normExternDecl(items, false),
                    .@"extern_const" => try self.normExternDecl(items, true),
                    .@"." => try self.normMember(items),
                    .@"pair" => try self.normKwarg(items),
                    .@"?" => try self.normOptional(items),
                    .@"for" => try self.normFor(items, false),
                    .@"for_ptr" => try self.normFor(items, true),
                    else => try self.walkChildren(sexp),
                };
            },
        }
    }

    fn walkChildren(self: *Normalizer, sexp: Sexp) !Sexp {
        const items = sexp.list;
        var out = try self.arena.alloc(Sexp, items.len);
        for (items, 0..) |child, i| {
            out[i] = try self.walk(child);
        }
        return Sexp{ .list = out };
    }

    // -------------------------------------------------------------------------
    // Bindings
    // -------------------------------------------------------------------------

    /// (= target expr) → (set target _ expr')
    /// Type slot is nil ("no annotation"); see normTyped for the typed form.
    fn normSet(self: *Normalizer, items: []const Sexp) !Sexp {
        return self.normBindWithType(items, .set, null);
    }

    /// Helper: given `(<head> name expr)`, emit `(<new_head> name <type> expr')`
    /// where `type` is the supplied node OR `_` (nil) if null. Used by `set`,
    /// `fixed_bind`, `shadow`, `typed_assign`, `typed_fixed`.
    fn normBindWithType(
        self: *Normalizer,
        items: []const Sexp,
        new_head: Tag,
        type_node: ?Sexp,
    ) !Sexp {
        if (items.len < 3) return self.rewriteHead(items, new_head);
        const target = try self.walk(items[1]);
        const expr = try self.walk(items[2]);
        const out = try self.arena.alloc(Sexp, 4);
        out[0] = .{ .tag = new_head };
        out[1] = target;
        out[2] = if (type_node) |t| try self.walk(t) else Sexp{ .nil = {} };
        out[3] = expr;
        return Sexp{ .list = out };
    }

    /// Raw typed forms from the parser collapse into the regular bind heads
    /// with the type slot populated:
    ///   (typed_assign name type expr) → (set        name type' expr')
    ///   (typed_fixed  name type expr) → (fixed_bind name type' expr')
    fn normTyped(self: *Normalizer, items: []const Sexp, new_head: Tag) !Sexp {
        if (items.len < 4) return self.rewriteHead(items, new_head);
        const target = try self.walk(items[1]);
        const t = try self.walk(items[2]);
        const expr = try self.walk(items[3]);
        const out = try self.arena.alloc(Sexp, 4);
        out[0] = .{ .tag = new_head };
        out[1] = target;
        out[2] = t;
        out[3] = expr;
        return Sexp{ .list = out };
    }

    /// (+= target expr) → (set_op += target expr')
    fn normSetOp(self: *Normalizer, items: []const Sexp) !Sexp {
        // Build (set_op <op-tag> <target'> <expr'>)
        var out = try self.arena.alloc(Sexp, items.len + 1);
        out[0] = .{ .tag = .set_op };
        out[1] = items[0]; // the original op-tag (+= -= *= /=)
        for (items[1..], 2..) |child, i| {
            out[i] = try self.walk(child);
        }
        return Sexp{ .list = out };
    }

    /// (move_assign target expr) → (set target _ (move expr'))
    fn normMoveAssign(self: *Normalizer, items: []const Sexp) !Sexp {
        if (items.len < 3) return self.normSet(items);
        const target = try self.walk(items[1]);
        const expr = try self.walk(items[2]);
        const move_pair = try self.arena.alloc(Sexp, 2);
        move_pair[0] = .{ .tag = .@"move" };
        move_pair[1] = expr;
        const out = try self.arena.alloc(Sexp, 4);
        out[0] = .{ .tag = .set };
        out[1] = target;
        out[2] = .{ .nil = {} };
        out[3] = .{ .list = move_pair };
        return Sexp{ .list = out };
    }

    /// (extern_var name type)   → (extern_decl _     name type)
    /// (extern_const name type) → (extern_decl fixed name type)
    fn normExternDecl(self: *Normalizer, items: []const Sexp, fixed: bool) !Sexp {
        if (items.len < 3) return self.walkChildren(.{ .list = items });
        const name = try self.walk(items[1]);
        const t = try self.walk(items[2]);
        const out = try self.arena.alloc(Sexp, 4);
        out[0] = .{ .tag = .extern_decl };
        out[1] = if (fixed) Sexp{ .tag = .fixed } else Sexp{ .nil = {} };
        out[2] = name;
        out[3] = t;
        return Sexp{ .list = out };
    }

    // -------------------------------------------------------------------------
    // Calls / access
    // -------------------------------------------------------------------------

    /// (. obj name) → (member obj name)
    fn normMember(self: *Normalizer, items: []const Sexp) !Sexp {
        return self.rewriteHead(items, .member);
    }

    /// (pair name expr) → (kwarg name expr')
    fn normKwarg(self: *Normalizer, items: []const Sexp) !Sexp {
        return self.rewriteHead(items, .kwarg);
    }

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// (? T) → (optional T') — only when in type position. The grammar uses
    /// (? T) only for optional-type at the moment (read borrow is (read x)),
    /// so this rewrite is safe everywhere.
    fn normOptional(self: *Normalizer, items: []const Sexp) !Sexp {
        return self.rewriteHead(items, .optional);
    }

    // -------------------------------------------------------------------------
    // For loops
    // -------------------------------------------------------------------------

    /// Per SPEC §"Semantic IR Nodes":
    ///   (for binding _ source body else?) →
    ///     (for <mode> binding source' body else?)
    /// where mode is one of `read`, `write`, `move`, or `_` (nil) for "no
    /// mode" (default iteration). The source's outer ownership wrapper
    /// (if any) is consumed into the mode position and the inner
    /// expression becomes the iterated value.
    ///
    /// `for_ptr` (Zag-inherited pointer iteration, with an extra binding)
    /// keeps its dedicated head Tag.
    fn normFor(self: *Normalizer, items: []const Sexp, is_ptr: bool) !Sexp {
        if (is_ptr) {
            return self.walkChildren(.{ .list = items });
        }
        if (items.len < 4) return self.walkChildren(.{ .list = items });

        const binding = try self.walk(items[1]);
        // items[2] is ptr_binding (always nil/_ for non-ptr in V1).
        const raw_source = items[3];
        const source = try self.walk(raw_source);

        var mode: Sexp = .{ .nil = {} };
        var unwrapped_source = source;
        if (source == .list and source.list.len >= 2 and source.list[0] == .tag) {
            switch (source.list[0].tag) {
                .@"read" => {
                    mode = .{ .tag = .@"read" };
                    unwrapped_source = source.list[1];
                },
                .@"write" => {
                    mode = .{ .tag = .@"write" };
                    unwrapped_source = source.list[1];
                },
                .@"move" => {
                    mode = .{ .tag = .@"move" };
                    unwrapped_source = source.list[1];
                },
                else => {},
            }
        }

        const body = try self.walk(items[4]);
        const has_else = items.len >= 6;
        const else_body = if (has_else) try self.walk(items[5]) else Sexp{ .nil = {} };

        const out_len: usize = if (has_else) 6 else 5;
        const out = try self.arena.alloc(Sexp, out_len);
        out[0] = .{ .tag = .@"for" };
        out[1] = mode;
        out[2] = binding;
        out[3] = unwrapped_source;
        out[4] = body;
        if (has_else) out[5] = else_body;
        return Sexp{ .list = out };
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// Replace head tag, walk children.
    fn rewriteHead(self: *Normalizer, items: []const Sexp, new_tag: Tag) !Sexp {
        var out = try self.arena.alloc(Sexp, items.len);
        out[0] = .{ .tag = new_tag };
        for (items[1..], 1..) |child, i| {
            out[i] = try self.walk(child);
        }
        return Sexp{ .list = out };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "normalize: = becomes set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var arena = arena_state.allocator();

    const tag_eq = Sexp{ .tag = .@"=" };
    const x = Sexp{ .str = "x" };
    const one = Sexp{ .str = "1" };
    var raw_items = [_]Sexp{ tag_eq, x, one };
    const raw = Sexp{ .list = &raw_items };

    var n = Normalizer.init(&arena);
    const out = try n.normalize(raw);

    try std.testing.expect(out == .list);
    try std.testing.expect(out.list[0] == .tag);
    try std.testing.expectEqual(Tag.set, out.list[0].tag);
}

test "normalize: move_assign desugars" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var arena = arena_state.allocator();

    const tag_ma = Sexp{ .tag = .move_assign };
    const a = Sexp{ .str = "a" };
    const b = Sexp{ .str = "b" };
    var raw_items = [_]Sexp{ tag_ma, a, b };
    const raw = Sexp{ .list = &raw_items };

    var n = Normalizer.init(&arena);
    const out = try n.normalize(raw);

    // expect (set a _ (move b)) — unified 4-child shape with type slot at items[2]
    try std.testing.expectEqual(Tag.set, out.list[0].tag);
    try std.testing.expect(out.list[2] == .nil);              // type slot
    try std.testing.expect(out.list[3] == .list);             // (move b)
    try std.testing.expectEqual(Tag.@"move", out.list[3].list[0].tag);
}

test "normalize: pair becomes kwarg" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var arena = arena_state.allocator();

    const tag_p = Sexp{ .tag = .pair };
    const n_node = Sexp{ .str = "name" };
    const v = Sexp{ .str = "Steve" };
    var raw_items = [_]Sexp{ tag_p, n_node, v };
    const raw = Sexp{ .list = &raw_items };

    var n = Normalizer.init(&arena);
    const out = try n.normalize(raw);

    try std.testing.expectEqual(Tag.kwarg, out.list[0].tag);
}
