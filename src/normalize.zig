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
const BindingKind = rig.BindingKind;

// =============================================================================
// IR queries (used by M2 ownership and M3 emit)
// =============================================================================

/// Decode the kind slot of a normalized binding form `(set <kind> ...)`
/// into the exhaustive `BindingKind` enum. The kind slot is `.nil` for
/// the default `=` form, or a `.tag` carrying one of the kind markers
/// (`.fixed`, `.shadow`, `.@"move"`, `.@"+="`, etc.).
///
/// Switching on the returned `BindingKind` at consumer sites lets Zig
/// enforce exhaustive coverage of every binding kind — adding a new
/// kind to the enum will break every dispatch site at compile time
/// until you handle it.
///
/// A kind slot we don't recognize falls through to `.default` rather
/// than panicking; in practice the normalizer only ever emits the
/// kinds listed above, so an unknown kind would indicate IR corruption.
pub fn bindingKindOf(kind_slot: Sexp) BindingKind {
    if (kind_slot == .nil) return .default;
    if (kind_slot != .tag) return .default;
    return switch (kind_slot.tag) {
        .fixed => .fixed,
        .shadow => .shadow,
        .@"move" => .@"move",
        .@"+=" => .@"+=",
        .@"-=" => .@"-=",
        .@"*=" => .@"*=",
        .@"/=" => .@"/=",
        else => .default,
    };
}

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
                    // All bindings collapse into (set <kind> name type-or-_ expr).
                    .@"=" => try self.normBind(items, .nil, null, false),
                    .@"+=" => try self.normBind(items, .{ .tag = .@"+=" }, null, false),
                    .@"-=" => try self.normBind(items, .{ .tag = .@"-=" }, null, false),
                    .@"*=" => try self.normBind(items, .{ .tag = .@"*=" }, null, false),
                    .@"/=" => try self.normBind(items, .{ .tag = .@"/=" }, null, false),
                    .@"fixed_bind" => try self.normBind(items, .{ .tag = .fixed }, null, false),
                    .@"shadow" => try self.normBind(items, .{ .tag = .shadow }, null, false),
                    .@"move_assign" => try self.normBind(items, .{ .tag = .@"move" }, null, false),
                    .@"typed_assign" => try self.normBind(items, .nil, items[2], true),
                    .@"typed_fixed" => try self.normBind(items, .{ .tag = .fixed }, items[2], true),
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

    /// Universal binding normalizer. Every raw binding form folds into:
    ///
    ///   (set <kind> name type-or-_ expr)
    ///
    /// The raw forms differ only in (a) which kind tag goes at position 1,
    /// and (b) whether a type annotation is attached (`typed` flag).
    ///
    ///   raw                            kind     typed?
    ///   (= name expr)                  _        no
    ///   (+= name expr) etc.            +=       no
    ///   (fixed_bind name expr)         fixed    no
    ///   (shadow name expr)             shadow   no
    ///   (move_assign name expr)        move     no
    ///   (typed_assign name type expr)  _        yes (items[2] is the type)
    ///   (typed_fixed name type expr)   fixed    yes
    fn normBind(
        self: *Normalizer,
        items: []const Sexp,
        kind: Sexp,
        type_node_in: ?Sexp,
        typed: bool,
    ) !Sexp {
        const min_arity: usize = if (typed) 4 else 3;
        if (items.len < min_arity) return self.walkChildren(.{ .list = items });

        const target = try self.walk(items[1]);
        const expr_raw = if (typed) items[3] else items[2];
        const expr = try self.walk(expr_raw);
        const type_node = if (type_node_in) |t| try self.walk(t) else Sexp{ .nil = {} };

        const out = try self.arena.alloc(Sexp, 5);
        out[0] = .{ .tag = .set };
        out[1] = kind;
        out[2] = target;
        out[3] = type_node;
        out[4] = expr;
        return Sexp{ .list = out };
    }

    /// (extern_var name type)   → (extern _     name type)
    /// (extern_const name type) → (extern fixed name type)
    ///
    /// Note: this reuses the `extern` Tag (which also serves as the
    /// decoration wrapper `(extern <child>)`). The two shapes are
    /// distinguishable: wrapper has 2 children with a list at items[1];
    /// standalone decl has 4 children with a tag/nil at items[1].
    fn normExternDecl(self: *Normalizer, items: []const Sexp, fixed: bool) !Sexp {
        if (items.len < 3) return self.walkChildren(.{ .list = items });
        const name = try self.walk(items[1]);
        const t = try self.walk(items[2]);
        const out = try self.arena.alloc(Sexp, 4);
        out[0] = .{ .tag = .@"extern" };
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

test "normalize: move_assign folds into (set move ...)" {
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

    // expect (set move a _ b) — unified 5-child shape with kind=move
    try std.testing.expectEqual(Tag.set, out.list[0].tag);
    try std.testing.expect(out.list[1] == .tag);
    try std.testing.expectEqual(Tag.@"move", out.list[1].tag);  // kind
    try std.testing.expect(out.list[3] == .nil);                // type slot
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
