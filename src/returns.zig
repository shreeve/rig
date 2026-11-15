//! Which functions never return: decided once, for the whole program,
//! after every module is checked (docs/internals/INTERNALS.md,
//! "Functions that never return").
//!
//! A function gives no value and cannot fail (its Zig result is `void`),
//! nothing in it returns or passes a failure or a `none` on outside its
//! closures (`rig.holdsExit`), and its body diverges: a statement
//! diverges when it is a `panic`, a call of a function already known
//! never to return, an `if` with an `else` whose branches both diverge,
//! a `match` whose arms all do (every `match` is exhaustive), a `loop`
//! no `break` leaves, or a block one of whose statements diverges. A
//! `break` or `continue` out of a diverging statement goes to a loop
//! inside the function, and a loop counts only when no `break` leaves
//! it, so nothing reaches the function's end. Emit writes the function's
//! Zig result `noreturn` (`Facts.neverReturns`), and LLVM drops each
//! caller's path past a call of it. No checker reads the fact: a call of
//! such a function is typed `Void` as before.
//!
//! What a call reaches is the target typecheck recorded where it
//! resolved the call (`SemContext.callTargetOf`). A call through an
//! actor's handle, a witness, or an API object never counts: the Zig
//! callee there is the runtime's, or a type parameter's. A generic
//! function is decided once, as Zig writes it once: typecheck checks its
//! body once, so its targets are the same at every instance. The
//! functions are marked by the least fixed point, so a function that
//! only calls itself, or a cycle of them, is not marked.
//!
//! The root module's `main`, which the runtime calls, a closure, a
//! `test` block, a `drop` body, and a compile-time function are never
//! candidates.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const modules = @import("modules.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const SemContext = sema.SemContext;

const Fn = struct {
    module: usize,
    body: Sexp,
    /// Where its name is declared, which `never_returns` keys by.
    pos: u32,
    never: bool = false,
    /// It holds an early exit (`rig.holdsExit`), asked once its body is
    /// first found to diverge.
    exits: ?bool = null,
};

const Pass = struct {
    mods: []const *modules.Module,
    fns: std.ArrayList(Fn) = .empty,
    /// Per module: the candidate declared at a position.
    by_pos: []std.AutoHashMapUnmanaged(u32, u32),

    fn ctx(self: *const Pass, module: usize) *const SemContext {
        return self.mods[module].sema;
    }

    /// Whether the call `call` of module `module` reaches a function
    /// known never to return.
    fn callNever(self: *const Pass, module: usize, call: Sexp) bool {
        const c = self.ctx(module);
        if (c.isActorCall(call)) return false;
        if (c.dispatchOf(call)) |d| if (d.viaApi()) return false;
        const ref = switch (c.callTargetOf(call) orelse return false) {
            .function => |r| r,
            .none => return false,
        };
        if (ref.module < 1 or ref.module > self.mods.len) return false;
        const f = self.by_pos[ref.module - 1].get(ref.pos) orelse return false;
        return self.fns.items[f].never;
    }

    /// Whether statement `s` of module `module` never finishes, but by a
    /// jump to a loop around it.
    fn diverges(self: *const Pass, module: usize, s: Sexp) bool {
        const source = self.ctx(module).source;
        const h = s.kind() orelse return false;
        return switch (h) {
            .panic => true,
            .call => self.callNever(module, s),
            .block => for (ir.Block.stmts(s)) |st| {
                if (self.diverges(module, st)) break true;
            } else false,
            .@"if" => ir.If.@"else"(s) != .nil and self.diverges(module, ir.If.then(s)) and self.diverges(module, ir.If.@"else"(s)),
            .match => for (ir.Match.arms(s)) |arm| {
                if (!self.diverges(module, ir.Arm.body(arm))) break false;
            } else ir.Match.arms(s).len > 0,
            .@"while", .labeled => sema.isLoop(source, s) and !sema.breaksOut(source, s, false),
            else => false,
        };
    }
};

pub fn decide(allocator: std.mem.Allocator, graph: *modules.ModuleGraph) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = try a.alloc(*modules.Module, graph.modules.items.len);
    for (graph.modules.items, mods) |*m, *out| out.* = m;
    var pass: Pass = .{ .mods = mods, .by_pos = try a.alloc(std.AutoHashMapUnmanaged(u32, u32), mods.len) };
    for (pass.by_pos) |*m| m.* = .empty;
    for (mods, 0..) |m, i| {
        const c = m.sema;
        for (c.frame_owners.items) |o| {
            if (o.kind != .function) continue;
            const node = o.root;
            const body = ir.get(node, .body);
            if (body == .nil) continue;
            const name = ir.get(node, .name);
            if (!o.member and m.id == 1 and name == .src and std.mem.eql(u8, rig.leafText(c.source, name.src), "main")) continue;
            const ty = c.typeOf(name) orelse continue;
            const f = switch (c.types.get(ty)) {
                .function => |f| f,
                else => continue,
            };
            if (f.returns != c.types.void_id) continue;
            try pass.by_pos[i].put(a, o.pos, @intCast(pass.fns.items.len));
            try pass.fns.append(a, .{ .module = i, .body = body, .pos = o.pos });
        }
    }
    // The least fixed point: each round marks what the marks so far
    // prove, until a round marks nothing.
    var changed = true;
    while (changed) {
        changed = false;
        for (pass.fns.items) |*f| {
            if (f.never or f.exits == true) continue;
            if (!pass.diverges(f.module, f.body)) continue;
            if (f.exits == null) f.exits = rig.holdsExit(f.body);
            if (f.exits.?) continue;
            f.never = true;
            changed = true;
        }
    }
    for (pass.fns.items) |f| if (f.never) try mods[f.module].sema.never_returns.put(allocator, f.pos, {});
}
