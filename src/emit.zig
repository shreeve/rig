//! Zig code generation.
//!
//! Lowers the semantic IR (`docs/internals/INTERNALS.md`) of one checked module to Zig
//! 0.17 source. The program has already passed sema and ownership
//! checking; this pass only chooses a representation, and it
//! reads everything it needs to know about names and types from sema's
//! facts table (`sema.zig`): which symbol a name denotes, whether a
//! `set` declares or reassigns, and the type of every expression.
//!
//! - A binding is `const` unless it is reassigned, written through
//!   (`!x`, `x.f = ...`), holds a Cell or a value with drop glue (whose
//!   methods take `*Self`), or has a compile-time-known initializer,
//!   which Zig would otherwise fold at compile time.
//! - A resource binding (`*T`, `~T`, a value with drop glue, or an
//!   optional of one) is dropped at scope exit by a `defer`. When the
//!   binding may be moved, dropped, or returned, the defer tests a
//!   `__rig_alive_<name>` flag, and the consuming site clears it. A
//!   field a use may move out of it (`Facts.fieldMoves`) has a flag of
//!   its own, and the drop takes only the fields still held
//!   (`rig.dropParts`).
//! - `!T` parameters, `!@` receivers, and write-view bindings are
//!   pointers; reads go through `.*`.
//! - Every Rig name is written with `rig.writeZigIdent` (`ident`), the
//!   one place a Rig name becomes a Zig name; a local that would shadow
//!   another visible Zig name, compared as Zig names, is renamed.
//!
//! Anything the emitter cannot lower is an internal error: sema must
//! reject it first.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const facts = @import("facts.zig");
const Facts = facts.Facts;
const Wide = facts.Wide;
const diag = @import("diag.zig");
const nametable = @import("nametable.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;

/// The runtime shipped with every emitted program: `src/runtime.zig`,
/// written byte for byte next to the emitted modules, which import it
/// as `rig`. A batch (`rig batch`) writes it once, as the Zig module
/// `runtime_module` every program of the batch imports.
pub const runtime_filename = "rig/runtime.zig";
pub const runtime_module = "rig";
pub const runtime_source = @embedFile("runtime.zig");
/// The runtime's tasks (`src/tasks.zig`), written beside it.
pub const tasks_filename = "rig/tasks.zig";
pub const tasks_source = @embedFile("tasks.zig");
/// The scheduler (`src/sched.zig`), written beside the runtime too.
pub const sched_filename = "rig/sched.zig";
pub const sched_source = @embedFile("sched.zig");

/// The allocator of release builds (`src/alloc.zig`), written beside the
/// runtime too.
pub const alloc_filename = "rig/alloc.zig";
pub const alloc_source = @embedFile("alloc.zig");

/// Sockets and the HTTP server (`src/net.zig`), written beside the runtime too.
pub const net_filename = "rig/net.zig";
pub const net_source = @embedFile("net.zig");
/// Tables (`src/table.zig`), written beside the runtime.
pub const table_filename = "rig/table.zig";
pub const table_source = @embedFile("table.zig");
/// The program's symbols, written next to the modules
/// (`src/symbols.zig`), which a module that writes one imports as
/// `__rig_sym`.
pub const symbols_filename = "__rig_symbols.zig";
/// The program's error glue: the size of its largest error member's
/// fields, and their drop, clone, `==`, and print (`writeErrorGlue`).
pub const errors_filename = "__rig_errors.zig";

/// A module of the program, for `writeErrorGlue`: its facts and the file
/// the glue imports it by.
pub const GlueModule = struct { facts: Facts, path: []const u8 };

/// `__rig_errors.zig`: one `Glue` for the whole program, which every
/// error with fields is read through (`rig.error_glue`): the size and
/// alignment of the largest member's fields, and drop, clone, `==`, and
/// print of member `code`'s fields, each a switch on the code. The root
/// module re-exports it as `__rig_error_glue`.
pub fn writeErrorGlue(a: std.mem.Allocator, w: *Writer, mods: []const GlueModule, runtime_path: []const u8) !void {
    try w.print("const std = @import(\"std\");\nconst rig = @import(\"{s}\");\n", .{runtime_path});
    const Member = struct { module: usize, set: []const u8, name: []const u8, facts: Facts, compares: facts.MemberCompares };
    var members: std.ArrayList(Member) = .empty;
    for (mods, 0..) |m, i| {
        var used = false;
        for (m.facts.symbols.items) |sym| {
            if (!sym.flags.error_set or sym.error_parts != null or facts.syntax.isProxy(sym)) continue;
            for (sym.fields orelse &.{}) |f| {
                if (!f.is_variant or f.payload == null or f.payload.?.len == 0) continue;
                try members.append(a, .{ .module = i, .set = sym.name, .name = f.name, .facts = m.facts, .compares = m.facts.memberCompares(f) });
                used = true;
            }
        }
        if (used) try w.print("const m{d} = @import(\"{s}\");\n", .{ i, m.path });
    }
    try w.writeAll("\npub const Glue = struct {\n    const Ops = rig.ErrorGlueOps;\n");
    // The size and alignment of the largest member's fields.
    for ([2][]const u8{ "size", "alignment" }) |what| {
        try w.print("    pub const {s}: usize = @max(1", .{what});
        for (members.items) |m| try w.print(", @{s}(m{d}.{f})", .{ if (what[0] == 's') "sizeOf" else "alignOf", m.module, ident(try std.fmt.allocPrint(a, "{s}__{s}", .{ m.set, m.name })) });
        try w.writeAll(");\n");
    }
    // `eql` and `hash` list only the members whose fields compare and
    // hash; the checkers let no other reach them.
    const Needs = enum { all, eq, hash };
    // (`marks` keeps a parameter no listed member reads from being unused.)
    const ops = [_]struct { head: []const u8, call: []const u8, other: []const u8, needs: Needs = .all, marks: []const u8 = "" }{
        .{ .head = "drop(code: anyerror, data: *rig.ErrData) void", .call = "drop(data)", .other = "{}" },
        .{ .head = "clone(code: anyerror, src: *const rig.ErrData, dst: *rig.ErrData) void", .call = "clone(src, dst)", .other = "{}" },
        .{ .head = "eql(code: anyerror, a: *const rig.ErrData, b: *const rig.ErrData) bool", .call = "eqlFields(a, b)", .other = "true", .needs = .eq, .marks = "_ = &a;\n        _ = &b;\n        " },
        .{ .head = "hash(code: anyerror, data: *const rig.ErrData) u64", .call = "hash(data)", .other = "0", .needs = .hash, .marks = "_ = &data;\n        " },
        .{ .head = "print(code: anyerror, data: *const rig.ErrData, w: *std.Io.Writer) std.Io.Writer.Error!void", .call = "print(rig.errorShown(code), data, w)", .other = "w.writeAll(rig.errorShown(code))" },
    };
    for (ops) |op| {
        try w.print("    pub fn {s} {{\n        {s}switch (code) {{\n", .{ op.head, op.marks });
        for (members.items) |m| {
            switch (op.needs) {
                .all => {},
                .eq => if (!m.compares.eq) continue,
                .hash => if (!m.compares.hash) continue,
            }
            try w.writeAll("            error.");
            try writeErrorName(w, m.facts, m.set, m.name);
            try w.print(" => return Ops(m{d}.{f}).{s},\n", .{ m.module, ident(try std.fmt.allocPrint(a, "{s}__{s}", .{ m.set, m.name })), op.call });
        }
        try w.print("            else => return {s},\n        }}\n    }}\n", .{op.other});
    }
    try w.writeAll("};\n");
}
const Tag = rig.Tag;
const Writer = std.Io.Writer;
const TypeId = facts.TypeId;
const SymbolId = facts.SymbolId;

pub const Error = std.mem.Allocator.Error || Writer.Error || error{Unsupported};
pub const UnitEvent = facts.UnitEvent;
const check_units = facts.check_units;
const self_check = facts.self_check;

/// How a resource binding is released (`sema.ResourceKind`).
const ResourceKind = facts.ResourceKind;

/// How a binding's scope-exit drop is armed.
const Guard = enum {
    /// Not dropped here (plain data, views, captures, loop elements).
    none,
    /// Always dropped at scope exit: `defer x.dropStrong();`.
    scope,
    /// Dropped at scope exit unless consumed first.
    flag,
};

const Local = struct {
    sym: SymbolId,
    /// The Zig spelling: a renamed or escaped identifier, or a path such
    /// as `__rig_self.cap_x` for a closure capture.
    zig_name: []const u8 = "",
    ty: ?TypeId = null,
    kind: ?ResourceKind = null,
    guard: Guard = .none,
    /// `zig_name` holds a pointer to the Rig value.
    is_ptr: bool = false,
    /// A closure literal bound to a name: calls lower to `.__rig_invoke(...)`.
    stack_closure: bool = false,
    /// Name of the alive flag when `guard == .flag`.
    flag: []const u8 = "",
    /// The local of the same symbol this one hides until its scope ends.
    shadowed: ?LocalRef = null,
    /// A parameter copied into `zig_name` at the top of the body: the
    /// name the signature gives it.
    param_name: []const u8 = "",
    /// A parameter of an inlined function, bound through `rig.rt`
    /// (`emitFunPrologue`).
    launder: bool = false,
    /// The fields a use may move out of it (`Facts.fieldMoves`), each a
    /// path of Rig field names, and the flag that says it is still held,
    /// which its move clears and its assignment sets (Core §5).
    parts: []const []const u8 = &.{},
    part_flags: []const []const u8 = &.{},
};

const LocalRef = struct { scope: u32, index: u32 };

/// An argument evaluated into the temporary `name`. An owned one is
/// dropped at scope exit while `flag` is set; the call clears it. With
/// `ptr`, `name` holds the address of `node`, which stays where it is.
const Hoisted = struct {
    node: Sexp,
    name: []const u8,
    flag: []const u8 = "",
    ptr: bool = false,
    /// The temporary holds the value as the optional it becomes where it
    /// goes (`emitLift`), already packed: an assignment's new value.
    lifted: bool = false,
};

/// How a branch yields its value: the value itself, or the address of
/// the leaf it takes (`Emitter.emitLeafPtr`).
const Yield = enum { value, leaf_ptr };

/// The slot an owning temporary is kept in until its statement ends,
/// and the flag saying it holds one.
const TempSlot = struct {
    node: parser.NodeId,
    name: []const u8,
};

/// The slot of the copy an API object views (`sema.Erasure.copy`),
/// declared before its statement: the erased value's node, by
/// `erasedKey`, and the slot's name.
const ErasedSlot = struct {
    key: u64,
    name: []const u8,
};

/// A key of an erased value's node, a leaf's or a list's.
fn erasedKey(n: Sexp) ?u64 {
    return switch (n) {
        .src => |x| x.pos,
        .list => |l| @as(u64, l.id) | 1 << 32,
        else => null,
    };
}

/// A header being emitted (`openHeader`): the label of the block that
/// holds its temporaries' slots, if it makes any, and the slots before.
const Header = struct { label: []const u8 = "", first: usize };

/// A label of the Zig a loop or labeled block is lowered to, written
/// before its construct only when a jump was written to it
/// (`openLabeled`), since Zig rejects a label nothing jumps to.
const ZigLabel = struct { name: []const u8, used: bool = false };

/// A loop, or a labeled `match` or `raw` block, that a `break` or
/// `continue` can go to, while it is emitted (docs/internals/INTERNALS.md,
/// "Loops"). A jump finds it by the construct its `JumpDest` names,
/// which the type checker resolved.
const JumpTarget = struct {
    /// The construct: the `while` or `for`, or the `match` or `raw` block.
    node: Sexp,
    /// Its Rig label, or "".
    rig_label: []const u8,
    /// Where a `break` goes: the loop's result block, or the loop.
    brk: *ZigLabel,
    /// The Zig loop, which `continue :loop` goes on with; null for a
    /// labeled block, which no `continue` names.
    loop: ?*ZigLabel = null,
    /// The body's block, which `break :body` leaves.
    body: ?*ZigLabel = null,
    /// The step's block, while the step is emitted.
    step: ?*ZigLabel = null,
    /// Where the loop's step runs; null for a loop with no step.
    step_point: ?facts.StepPoint = null,
    /// The part of the loop being emitted, which decides the Zig jump a
    /// `continue` is: `continue :loop` from the condition, `break :body`
    /// from the body, and `break :step` from the step.
    part: LoopPart = .cond,
    /// The type of a loop used as a value, whose `break` gives it one.
    value_ty: ?TypeId = null,
};

const LoopPart = enum { cond, body, step };

/// A labeled construct being written into a buffer of its own, until
/// `closeLabeled` knows whether its label is used.
const Labeled = struct { label: *ZigLabel, saved: *Writer, buf: *Writer.Allocating };

const Scope = struct {
    locals: std.ArrayList(Local) = .empty,
    /// The statements whose flags were written in the scope
    /// (`Emitter.flag_names`), out of reach once it ends.
    flags: std.ArrayList(facts.NodeKey) = .empty,
};

/// State for the function whose body is being emitted.
const FunState = struct {
    /// Declared return type.
    return_ty: ?TypeId = null,
    /// The function takes `__out`: it may fail with fields, which a
    /// failing `return` stores through it (errors-spec §7.1).
    has_out: bool = false,
    /// The name of the slot parameter: `__out`, and in a closure,
    /// `__out_N` by its depth, since Zig lets no parameter shadow another.
    out_name: []const u8 = "__out",
    /// `__out` is not yet marked used: the body's first line does
    /// (`_ = &__out;`), as a function that never fails with fields
    /// leaves it unread.
    out_unmarked: bool = false,
    /// `main`, which may fail with fields: it holds its own slot.
    main_slot: bool = false,
    /// Parameters to bind at the top of the body.
    params: ?Sexp = null,
    /// Compile-time parameters, bound at the top of the body as
    /// `params` are.
    tparams: Sexp = .nil,
    leak_check: bool = false,
    /// The function is emitted `inline`: its parameters are bound as
    /// run-time values (`emitFunPrologue`).
    inlined: bool = false,
    /// The function is cold (its body starts with `rarely`, or it always
    /// panics): its body starts with `@branchHint(.cold)`, which Zig
    /// takes only as the first statement.
    cold: bool = false,
    /// A closure's environment parameter, when no capture is used.
    unused_env: []const u8 = "",
    /// The witness parameters of a method under bounds on its type's
    /// parameters (`W_T_Shape`), read by type at the top of its body.
    owner_witnesses: []const []const u8 = &.{},
    /// The captures a closure called exactly once takes from its
    /// environment, bound at the top of its body as parameters are
    /// (`SemContext.recordOnceClosure`).
    once_caps: []const SymbolId = &.{},
    /// The environment of a closure its callee calls at most once, which
    /// its call marks called (`emitFunPrologue`).
    once_env: []const u8 = "",
    /// The body's first statement is still to come: it raises Zig's
    /// compile-time evaluation budget (`rig.eval_quota`).
    quota: bool = true,
    /// The function is one every cycle of calls passes through some
    /// one of: its body starts with a yield check
    /// (`Emitter.yield_checks`, `Facts.hasEntryCheck`).
    entry_check: bool = false,
    /// How many loops the code being emitted is inside.
    loops: u32 = 0,
    /// The count of turns of the outermost loop the code being emitted is
    /// inside (`Emitter.yield_checks`), which every loop in it counts
    /// down too.
    turns: ?[]const u8 = null,
};

const Nominal = struct {
    /// How `Self` is spelled: the type name, or `__rig_Self` inside a generic.
    name: []const u8,
    sym: SymbolId,
    members: []const Sexp,
    /// The Zig name of each of its methods (`ident`).
    methods: []const []const u8,
};

/// Facts about bindings the emitter derives from one walk over the
/// module, keyed by symbol.
const Usage = struct {
    /// Referenced somewhere after the declaration.
    used: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

    fn deinit(self: *Usage, a: std.mem.Allocator) void {
        self.used.deinit(a);
    }
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    w: *Writer,
    indent: u32 = 0,
    /// Generated names and other emit-lifetime allocations.
    arena: std.heap.ArenaAllocator,
    facts: Facts,

    scopes: std.ArrayList(Scope) = .empty,
    /// Symbol -> its innermost local in `scopes`.
    local_by_sym: std.AutoHashMapUnmanaged(SymbolId, LocalRef) = .empty,
    /// The Zig names of the locals in `scopes`, with how many locals use each.
    local_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Suffix source for generated labels, temporaries, and renames.
    counter: u32 = 0,
    /// Every module-level Zig name, which locals must not shadow.
    module_names: std.StringHashMapUnmanaged(void) = .empty,
    /// The modules whose `@import` is emitted so far: in a directory
    /// module, several files may each use one module.
    used_modules: std.AutoHashMapUnmanaged(u32, void) = .empty,
    usage: Usage = .{},
    /// `test` blocks emitted so far: the Rig name literal and the Zig function.
    tests: std.ArrayList(struct { name: []const u8, func: []const u8 }) = .empty,
    fun: FunState = .{ .quota = false },
    /// The result the `result_part` being emitted takes: `__rig_res_N[j]`,
    /// of the destructure whose target it is (`emitDestructure`).
    part_name: []const u8 = "",
    /// Closure bodies being emitted around the current point. Each names
    /// its environment `__rig_self`, `__rig_self1`, ... so a closure
    /// inside another does not shadow the outer one's.
    closure_depth: u32 = 0,
    nominal: ?Nominal = null,
    /// The module's additions (`add Int: Shape`), whose methods its
    /// witnesses hold (`emitWitnesses`).
    additions: std.ArrayList(Sexp) = .empty,
    /// The next expression sits in a delimited position (after `=`,
    /// between commas, inside parentheses) and needs no outer parentheses.
    bare: bool = false,
    /// The value being emitted is a write view: a pointer local in tail
    /// position yields the pointer, not the value behind it.
    ptr_tail: bool = false,
    /// What the context of the value being emitted does with it
    /// (`facts.Use`), and the value it was recorded for or a part of that
    /// value (`facts.syntax.valueParts`) the use reaches.
    use: ?facts.Use = null,
    use_node: Sexp = .nil,
    /// The value parts of each `match` that has been the value whose use
    /// is known, by the match (`partOfUse`), found once so that telling
    /// whether a value is one of them walks no arm.
    match_parts: std.AutoHashMapUnmanaged(PartKey, std.AutoHashMapUnmanaged(PartKey, void)) = .empty,
    /// The next expression is emitted as the pointer it yields, even where
    /// its context reads through it (`emitDeref`).
    want_ptr: bool = false,
    /// Emitting an operand of arithmetic or an index: compile-time names
    /// (compile-time parameters, `=!` bindings) are read through `rig.rt` so Zig
    /// evaluates the operation at run time, as Rig checked it.
    rt_names: bool = false,
    /// Emitting a compile-time argument, which must stay compile-time known.
    keep_comptime: bool = false,
    /// Emitting an operand of arithmetic in a float type or a type
    /// parameter: an integer literal is a value of that type, so `7 / 2`
    /// in a `Float` is `3.5`, and in a `T` divides as `T`'s instance does.
    literal_ty: ?TypeId = null,
    /// Emitting the object chain of an assignment target: an indexed
    /// element in it is a slot, not a copy.
    place_chain: bool = false,
    /// The value `emitLend` is lending, which it emits as itself.
    lending: Sexp = .nil,
    /// The error value a failing `return` is sending through `__out`.
    failing: Sexp = .nil,
    /// The code-only error being made a `rig.ErrorValue` (`isCodeWidening`).
    widening: Sexp = .nil,
    /// The scalar operand being written splatted (`sema.splatOf`).
    splatting: Sexp = .nil,
    /// The box being erased to a box of an API object (`emitValue`).
    erasing_box: Sexp = .nil,
    /// Arguments and receivers of the calls being emitted that were
    /// evaluated into temporaries first (`emitHoistedCall`), innermost
    /// call last.
    hoisted: std.ArrayList(Hoisted) = .empty,
    /// The owning temporaries of the statements being emitted, each held
    /// in a slot its statement drops (`sema.dropsTemp`).
    temp_slots: std.ArrayList(TempSlot) = .empty,
    /// The slots of the copies the statements being emitted erase
    /// (`emitErasedSlots`).
    erased_slots: std.ArrayList(ErasedSlot) = .empty,
    /// The temporary whose value is being written into its slot.
    keeping: Sexp = .nil,
    /// The loops and labeled blocks around the current point that a jump
    /// can name, innermost last.
    targets: std.ArrayList(JumpTarget) = .empty,
    /// The place being emitted is only read: a List element on its path
    /// is reached through `constSlot`.
    read_place: bool = false,
    /// The `match` subject being emitted, which it reaches where it is
    /// (`storage.matchesInPlace`): a generic read view held on its path,
    /// by its name, a field, or an element, is the value it reaches in
    /// place, `rig.viewedPtr(T, &view).*`, never a copy (`onSubjectPath`).
    subject_path: Sexp = .nil,
    /// A name was qualified as `__rig_module.name` (`writeModuleName`).
    uses_module: bool = false,
    /// A `$name` of a type parameter needs the module's table of names
    /// (`emitNamesTable`).
    uses_names: bool = false,
    /// A symbol or the type `Symbol` is written, so the module imports
    /// the program's symbols as `__rig_sym` (`src/symbols.zig`).
    uses_symbols: bool = false,
    /// The module declares an `extern "c"`, so the program links libc.
    links_libc: bool = false,
    /// Fill each hidden storage location with `0xAA` when its scope ends
    /// (`rig.poison`), so a view that outlives it reads garbage: set for
    /// the sanitizer (`RIG_SANITIZE`).
    poison: bool = false,
    /// The Zig error set of every error of the module's error sets,
    /// which its fallible Zig-backed functions may return.
    module_errors: []const u8 = "error{}",
    /// The statement or declaration being emitted, where an internal
    /// error about a node without a position is reported.
    stmt: Sexp = .nil,
    /// The units whose code is being written, innermost last
    /// (`enterUnit`): each check, write, and hidden storage emit writes
    /// lies in the innermost (`inUnit`).
    units: std.ArrayList(facts.NodeKey) = .empty,
    /// The units emit stopped writing to write others' code, which it
    /// takes up again (`pauseUnit`).
    paused: std.AutoArrayHashMapUnmanaged(facts.NodeKey, void) = .empty,
    /// When set, the units in the order their code runs, and where each
    /// jump goes: the unit-order test of the proof pass
    /// (`proofs.checkUnitOrder`).
    unit_trace: ?*std.ArrayList(UnitEvent) = null,
    /// Write every test, ignoring which are known to pass (`provenOf`):
    /// `RIG_NO_PROOFS`, for the differential run of the proofs.
    no_proofs: bool = false,
    /// The Zig name of each flag written (`emitFlag`), by the statement
    /// it is made before; a test proven while a flag holds is written so
    /// only once its flag is (`provenIf`).
    flag_names: std.AutoHashMapUnmanaged(facts.NodeKey, []const u8) = .empty,
    /// Hold every object's optional as a tagged struct, so the program
    /// compiles only if every operation on one goes through the optional
    /// helpers (`RIG_STRICT_OPTIONALS`, `Facts.optionalRouted`).
    strict_optionals: bool = false,
    /// The program makes tasks: its loops count their turns toward a
    /// yield check (`rig.turn`), and every cycle of its calls passes a
    /// check for work left waiting (`rig.tickCall`), so no task keeps
    /// the others waiting for long.
    yield_checks: bool = false,
    /// While a `T!E`'s error set is written: the Zig set of its codes,
    /// never the `rig.ErrorValue` a value of it is.
    error_codes: bool = false,
    /// The call a `!` or `catch` is being written for, and the slot it
    /// lends that call, when the call may fail with fields: `emitArgs`
    /// passes it last.
    fail_slot: ?struct { call: Sexp, expr: []const u8 } = null,
    /// What the module imports the runtime by: its file in the package,
    /// or the module a batch shares (`runtime_module`).
    runtime_import: []const u8 = runtime_filename,
    /// The module's files, each by its path from the package root, which
    /// a `panic` names where it stands.
    file: diag.File = .{ .source = "", .path = "" },
    /// The value being written inside the `rig.pack` of the optional it
    /// becomes (`emitLift`), or written where it is held as itself.
    lifting: Sexp = .nil,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer, ctx: Facts) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .facts = ctx,
        };
    }

    pub fn deinit(self: *Emitter) void {
        for (self.scopes.items) |*s| s.locals.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.local_by_sym.deinit(self.allocator);
        self.local_names.deinit(self.allocator);
        self.module_names.deinit(self.allocator);
        self.used_modules.deinit(self.allocator);
        self.usage.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.hoisted.deinit(self.allocator);
        self.temp_slots.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.units.deinit(self.allocator);
        self.flag_names.deinit(self.allocator);
        self.paused.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        try self.w.print("const rig = @import(\"{s}\");\n", .{self.runtime_import});
        if (!sexp.isKind(.module)) return;
        const decls = ir.Module.decls(sexp);
        try self.collectModule(decls);
        for (decls) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            if (!d.isKind(.errors)) continue;
            const set = try self.fmt("{f}", .{ident(self.srcText(ir.Errors.name(d)))});
            self.module_errors = if (std.mem.eql(u8, self.module_errors, "error{}")) set else try self.fmt("{s} || {s}", .{ self.module_errors, set });
        }
        var scan: Scan = .{ .e = self };
        try scan.walk(sexp);
        for (decls) |decl| {
            // A compile-time function runs in the checker; its calls are
            // the values it computed. An addition's methods are written in
            // its witnesses (`emitWitnesses`).
            if (rig.isCtFun(decl)) continue;
            if (rig.unpub(decl).isKind(.api_add)) {
                try self.additions.append(self.allocator, rig.unpub(decl));
                continue;
            }
            try self.w.writeAll("\n");
            try self.emitDecl(decl);
        }
        try self.emitWitnesses();
        try self.emitCtHidden();
        try self.emitTestTable();
        if (self.uses_module) try self.w.writeAll("\nconst __rig_module = @This();\n");
        if (self.uses_names) try self.emitNamesTable();
        for ([_]SymbolId{ self.facts.endian_sym_id, self.facts.arch_sym_id, self.facts.order_sym_id }) |sym| if (self.facts.hasTextTable(sym)) try self.emitTextTable(sym);
        if (self.uses_symbols) try self.w.print("\nconst __rig_sym = @import(\"{s}\");\n", .{symbols_filename});
    }

    // =========================================================================
    // Module-level declarations
    // =========================================================================

    fn collectModule(self: *Emitter, decls: []const Sexp) Error!void {
        const a = self.allocator;
        try self.module_names.put(a, "std", {});
        try self.module_names.put(a, "rig", {});
        for (decls) |d0| {
            if (d0.isKind(.zig_extern)) try self.collectModule(ir.ZigExtern.decls(d0));
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            const kind = d.kind() orelse continue;
            const name = if (kind == .set) ir.Set.target(d) else if (ir.has(kind, .name)) ir.get(d, .name) else continue;
            if (name != .src) continue;
            try self.module_names.put(a, try self.fmt("{f}", .{ident(self.srcText(name))}), {});
        }
    }

    fn emitDecl(self: *Emitter, sexp: Sexp) Error!void {
        self.stmt = sexp;
        switch (sexp.kind().?) {
            // Every declaration is emitted `pub`, so `pub` adds nothing.
            .@"pub" => try self.emitDecl(ir.Pub.decl(sexp)),
            .fun, .sub => try self.emitFun(sexp),
            .extern_fun, .extern_sub => try self.emitExtern(ir.get(sexp, .name)),
            .zig_extern => try self.emitZigExtern(sexp),
            .@"extern" => try self.emitExtern(ir.Extern.name(sexp)),
            .use => try self.emitUse(sexp),
            .@"struct" => try self.emitStruct(sexp),
            .@"enum" => try self.emitEnum(sexp),
            .errors => try self.emitErrorSet(sexp),
            .error_join => try self.emitErrorJoin(sexp),
            .generic_struct => try self.emitGenericStruct(sexp),
            .generic_enum => try self.emitGenericEnum(sexp),
            .api => try self.emitApi(sexp),
            .type => try self.emitTypeAlias(sexp),
            .@"test" => try self.emitTest(sexp),
            .set => try self.emitConst(sexp),
            else => return self.unsupported(sexp, "this top-level form"),
        }
    }

    /// The hidden constants of the module's compile-time array values, each
    /// written once, however many calls read it (`cteval.recordCall`).
    fn emitCtHidden(self: *Emitter) Error!void {
        for (self.facts.ctHidden(), 0..) |h, i| {
            try self.w.print("\nconst __rig_ct_{d}: ", .{i});
            try self.emitTypeTy(h.ty);
            try self.w.writeAll(" = ");
            try self.writeCtValue(h.value, h.ty);
            try self.w.writeAll(";\n");
        }
    }

    /// A compile-time call's value: the hidden constant that holds an
    /// array, or the value written out.
    fn emitCtCall(self: *Emitter, r: facts.CtResult) Error!void {
        if (r.hidden) |i| return self.w.print("__rig_ct_{d}", .{i});
        try self.writeCtValue(r.value, r.ty);
    }

    /// Value `v` of type `ty` as a Zig literal: `@as(i64, 7)`, `true`,
    /// `@as(Mode, .loose)`, `[_]i64{ 0, 1, 4 }`.
    fn writeCtValue(self: *Emitter, v: facts.CtVal, ty: TypeId) Error!void {
        switch (v) {
            .int => |i| {
                try self.writeAsOpen(ty);
                try self.w.print("{d})", .{i});
            },
            .boolean => |b| try self.w.writeAll(if (b) "true" else "false"),
            .variant => |i| {
                try self.writeAsOpen(ty);
                try self.w.print(".{f})", .{ident(self.facts.variantName(ty, i))});
            },
            .array => |arr| {
                const elem = self.facts.types.get(ty).array.elem;
                try self.w.writeAll("[_]");
                try self.emitTypeTy(elem);
                try self.w.writeAll("{ ");
                for (0..arr.len()) |k| {
                    if (k > 0) try self.w.writeAll(", ");
                    const e = arr.at(k);
                    switch (e) {
                        .int => |n| try self.w.print("{d}", .{n}),
                        .boolean => |b| try self.w.writeAll(if (b) "true" else "false"),
                        .variant => |n| try self.w.print(".{f}", .{ident(self.facts.variantName(elem, n))}),
                        .array => try self.writeCtValue(e, elem),
                    }
                }
                try self.w.writeAll(" }");
            },
        }
    }

    /// A module-level constant, `name = value`. A vector is a Zig `var`,
    /// never written: Zig knows no vector when it compiles
    /// (`writeVectorOpen`), and LLVM still folds the never-written value.
    fn emitConst(self: *Emitter, node: Sexp) Error!void {
        const target = ir.Set.target(node);
        const ty = self.typeOf(target) orelse return self.unsupported(node, "an untyped constant");
        const vector = self.facts.types.get(ty) == .simd;
        try self.w.print("pub {s} {f}: ", .{ if (vector) "var" else "const", ident(self.srcText(target)) });
        try self.emitTypeTy(ty);
        try self.w.writeAll(" = ");
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        self.keep_comptime = true;
        try self.emitBare(ir.Set.value(node));
        try self.w.writeAll(";\n");
    }

    /// A `use` imports the module's emitted file under a name of the
    /// emitter's (`writeModuleZig`), whatever name the `use` binds: a
    /// `use` binds its name in its own file only, and a local of any
    /// file may have it.
    fn emitUse(self: *Emitter, node: Sexp) Error!void {
        const path = ir.Use.name(node);
        const alias = ir.Use.alias(node);
        const name = if (alias != .nil) alias else if (path.isKind(.member)) ir.Member.name(path) else path;
        const sym = self.facts.symbolOf(name) orelse return self.unsupported(node, "an unresolved `use`");
        const module = self.facts.moduleOf(sym) orelse return self.unsupported(node, "an unresolved `use`");
        if ((try self.used_modules.getOrPut(self.allocator, module)).found_existing) return;
        const foreign = self.facts.foreign(module) orelse return self.unsupported(node, "an unloaded module");
        try self.w.writeAll("const ");
        try self.writeModuleZig(module);
        try self.w.print(" = @import(\"{s}\");\n", .{foreign.zig_file});
    }

    /// The Zig name of an imported module: `__rig_m<id>_<name>`.
    fn writeModuleZig(self: *Emitter, module: u32) Error!void {
        const name = if (self.facts.foreign(module)) |f| f.name else "";
        try self.w.print("__rig_m{d}_", .{module});
        for (name) |c| try self.w.writeByte(if (c == '.') '_' else c);
    }

    /// `extern_fun` / `extern_sub`, a C function, or `extern`, a C
    /// variable.
    fn emitExtern(self: *Emitter, name_node: Sexp) Error!void {
        self.links_libc = true;
        const ty = try self.declType(name_node);
        const f = self.fnType(ty) orelse {
            try self.w.print("extern \"c\" var {f}: ", .{ident(self.srcText(name_node))});
            try self.emitTypeTy(ty);
            return self.w.writeAll(";\n");
        };
        try self.w.print("extern \"c\" fn {f}(", .{ident(self.srcText(name_node))});
        try self.emitTypeList(f.params);
        try self.w.writeAll(") ");
        try self.emitTypeTy(f.returns);
        try self.w.writeAll(";\n");
    }

    /// `extern zig "file.zig"`: each declaration is the function of the
    /// same name in the standard library's Zig file, written beside the
    /// runtime as `rig/std/file.zig`, and a compile-time check that its
    /// Zig type is exactly the one the Rig signature lowers to. A
    /// fallible one's Zig function returns a narrower error set, only of
    /// the module's errors (`rig.expectShim`), so the declaration is a
    /// function of the Rig type that calls it.
    fn emitZigExtern(self: *Emitter, node: Sexp) Error!void {
        const file = self.srcText(ir.ZigExtern.file(node));
        const shim = try self.fmt("__rig_shim_{d}", .{self.nextId()});
        try self.w.print("const {s} = @import(\"rig/std/{s}\");\n", .{ shim, file[1 .. file.len - 1] });
        for (ir.ZigExtern.decls(node)) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            const name = ir.get(d, .name);
            // A constant: Zig's value, coerced to the type Rig declares,
            // so Zig compiles a branch on it as a compile-time choice.
            if (d.isKind(.zig_const)) {
                try self.w.print("pub const {f}: ", .{ident(self.srcText(name))});
                try self.emitTypeTy(try self.declType(name));
                try self.w.print(" = {s}.{f};\n", .{ shim, exactIdent(self.srcText(name)) });
                continue;
            }
            const f = self.fnType(try self.declType(name)) orelse return self.unsupported(name, "an untyped function");
            if (self.facts.types.get(f.returns) == .fallible) {
                try self.w.print("pub fn {f}(", .{ident(self.srcText(name))});
                for (f.params, 0..) |p, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("__rig_a{d}: ", .{i});
                    try self.emitTypeTy(p);
                }
                // Zig fails with codes alone, but takes the slot a
                // function that may fail with fields is called with.
                const out = self.failsWithFields(f.returns);
                if (out) try self.w.writeAll(if (f.params.len > 0) ", __out: rig.ErrSlot" else "__out: rig.ErrSlot");
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
                try self.w.writeAll(" {\n");
                if (out) try self.w.writeAll("    _ = __out;\n");
                try self.w.print("    return {s}.{f}(", .{ shim, exactIdent(self.srcText(name)) });
                for (0..f.params.len) |i| try self.w.print("{s}__rig_a{d}", .{ if (i > 0) ", " else "", i });
                try self.w.writeAll(");\n}\n");
            } else {
                try self.w.print("pub const {f} = {s}.{f};\n", .{ ident(self.srcText(name)), shim, exactIdent(self.srcText(name)) });
            }
            try self.w.print("comptime {{\n    rig.expectShim({s}.{f}, fn (", .{ shim, exactIdent(self.srcText(name)) });
            try self.emitTypeList(f.params);
            try self.w.writeAll(") ");
            if (f.returns == self.facts.types.void_id) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
            try self.w.print(", {s}, \"{s}.{s}\");\n}}\n", .{ self.module_errors, self.facts.name, self.srcText(name) });
        }
    }

    fn emitTypeAlias(self: *Emitter, node: Sexp) Error!void {
        const name = ir.Type.name(node);
        const ty = try self.declType(name);
        // An alias of a bare API object's type names it for `$name`
        // alone.
        if (self.facts.objectBare(ty)) return;
        try self.w.print("pub const {f} = ", .{ident(self.srcText(name))});
        try self.emitTypeTy(ty);
        try self.w.writeAll(";\n");
    }

    /// The type sema gave the declaration named by `name_node`.
    fn declType(self: *Emitter, name_node: Sexp) Error!TypeId {
        const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved declaration");
        return self.symType(sym) orelse self.unsupported(name_node, "an untyped declaration");
    }

    /// `(test "name" body)` → a function listed in the module's
    /// `__rig_tests` table, which `rig test` runs (`rig.runTests`). Only
    /// the root module's tests are emitted; an imported module's are
    /// checked and left out.
    fn emitTest(self: *Emitter, node: Sexp) Error!void {
        if (!self.facts.is_root) return;
        const func = try self.fmt("__rig_test_{d}", .{self.tests.items.len});
        try self.tests.append(self.allocator, .{ .name = self.srcText(ir.Test.name(node)), .func = func });
        // A test that may fail with fields is given the slot they go in,
        // which `rig.runTests` shows and drops.
        try self.w.print("fn {s}(__out: rig.ErrSlot) anyerror!void ", .{func});
        self.fun = .{ .has_out = true, .out_unmarked = true };
        try self.emitBlock(ir.Test.body(node));
        try self.w.writeAll("\n");
    }

    /// A test's last line, or a `return` in a test, that gives the
    /// `Bool` deciding it: `false` hands `rig.testFalse` the report, and
    /// a `return` then ends the test.
    fn emitTestCheck(self: *Emitter, stmt: Sexp, report: []const u8) Error!void {
        const returns = stmt.isKind(.@"return");
        if (returns) try self.w.writeAll("{ ");
        try self.w.writeAll("if (!(");
        try self.emitBare(if (returns) ir.Return.value(stmt) else stmt);
        try self.w.print(")) rig.testFalse(\"{f}\");", .{std.zig.fmtString(report)});
        if (returns) try self.w.writeAll(" return; }");
    }

    fn emitTestTable(self: *Emitter) Error!void {
        if (self.tests.items.len == 0) return;
        try self.w.writeAll("\npub const __rig_tests = [_]rig.Test{\n");
        for (self.tests.items) |t| {
            try self.w.writeAll("    .{ .name = ");
            if (t.name[0] == '\'') try writeSingleQuoted(self.w, t.name) else try self.w.writeAll(t.name);
            try self.w.print(", .func = {s} }},\n", .{t.func});
        }
        try self.w.writeAll("};\n");
    }

    // -------------------------------------------------------------------------
    // Nominal types
    // -------------------------------------------------------------------------

    /// `(struct Name (: field type)... methods...)`.
    fn emitStruct(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Struct.name(node));
        const members = ir.Struct.members(node);
        try self.w.print("pub const {f} = struct {{\n", .{ident(name)});
        const prev = try self.enterNominal(ir.Struct.name(node), false, members);
        defer self.nominal = prev;
        try self.emitFields(1);
        try self.emitRigName(1);
        try self.emitOwnApis(1);
        try self.emitStrictOptional(1);
        try self.emitNamedNone(1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// An object that names its none (`none id == 0`): the field and the
    /// value its optional holds for `none` (`rig.Opt`, `rig.notNone`).
    fn emitNamedNone(self: *Emitter, depth: u32) Error!void {
        const sym = self.nominal.?.sym;
        const none = self.facts.namedNoneOfSym(sym) orelse return;
        const field = for (self.facts.symbols.items[sym].fields orelse &.{}) |f| {
            if (std.mem.eql(u8, f.name, none.field)) break f;
        } else return self.unsupported(.nil, "an object's none without its field");
        try self.writeIndent(depth);
        try self.w.print("pub const __rig_none_field = \"{f}\";\n", .{std.zig.fmtString(none.field)});
        try self.writeIndent(depth);
        try self.w.writeAll("pub const __rig_none: ");
        try self.emitTypeTy(field.ty);
        if (none.variant) |v| try self.w.print(" = .{f};\n", .{ident(v)}) else try self.w.print(" = {d};\n", .{none.value});
        // Its optional is the size of the object itself.
        try self.writeIndent(depth);
        try self.w.writeAll("comptime {\n");
        try self.writeIndent(depth + 1);
        try self.w.writeAll("if (@sizeOf(rig.Opt(@This())) != @sizeOf(@This())) @compileError(\"rig: an object's optional is larger than the object, though it names its none\");\n");
        try self.writeIndent(depth);
        try self.w.writeAll("}\n");
    }

    /// Under `RIG_STRICT_OPTIONALS`, the object being emitted asks for its
    /// optional to be held as a tagged struct (`rig.Opt`).
    fn emitStrictOptional(self: *Emitter, depth: u32) Error!void {
        if (!self.strict_optionals or !self.facts.isObjectSym(self.nominal.?.sym)) return;
        try self.writeIndent(depth);
        try self.w.writeAll("pub const __rig_strict_optional = {};\n");
    }

    /// `(generic_struct Name (T...) members...)` → a type-returning function.
    fn emitGenericStruct(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericStruct.members(node);
        const prev = try self.enterNominal(ir.GenericStruct.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericStruct.tparams(node), "struct");
        try self.emitFields(2);
        try self.emitRigName(2);
        try self.emitOwnApis(2);
        try self.emitStrictOptional(2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(enum Name variants... methods...)`: a Zig enum, an enum with
    /// explicit values, or a tagged union when any variant has a payload.
    fn emitEnum(self: *Emitter, node: Sexp) Error!void {
        const name = self.srcText(ir.Enum.name(node));
        const members = ir.Enum.members(node);
        const prev = try self.enterNominal(ir.Enum.name(node), false, members);
        defer self.nominal = prev;

        var has_values = false;
        var has_payloads = false;
        for (members) |m| {
            if (m.isKind(.valued)) has_values = true;
            if (m.isKind(.variant)) has_payloads = true;
        }
        if (has_payloads) {
            try self.w.print("pub const {f} = union(enum) {{\n", .{ident(name)});
            try self.emitUnionVariants(1);
            } else {
            try self.w.print("pub const {f} = enum{s} {{\n", .{ ident(name), if (has_values) "(u32)" else "" });
            for (self.nominalFields()) |f| {
                if (!f.is_variant) continue;
                try self.w.print("    {f}", .{ident(f.name)});
                if (has_values) try self.w.print(" = {d}", .{f.value.?});
                try self.w.writeAll(",\n");
            }
            if (self.facts.hasTextTable(self.nominal.?.sym)) try self.emitTextTable(self.nominal.?.sym);
        }
        try self.emitRigName(1);
        try self.emitOwnApis(1);
        try self.emitMethods(members, 1);
        try self.w.writeAll("};\n");
    }

    /// `__rig_text: rig.NameTable = ...;`: the table of plain enum
    /// `sym`'s names, in declaration order, which `E.from_text(word)`
    /// looks `word` up in (`rig.enumFromText`). A declared enum holds it
    /// as `E.__rig_text`; a module that looks up a built-in enum's names
    /// holds the table itself, as `__rig_text_Endian` or `__rig_text_Arch`.
    fn emitTextTable(self: *Emitter, sym: SymbolId) Error!void {
        const a = self.arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        for (self.facts.symbols.items[sym].fields orelse &.{}) |f| if (f.is_variant) try names.append(a, f.name);
        if (self.facts.isBuiltinEnum(sym)) {
            try self.w.print("\nconst __rig_text_{s}: rig.NameTable = ", .{self.facts.symbols.items[sym].name});
        } else try self.w.writeAll("    pub const __rig_text: rig.NameTable = ");
        try nametable.write(self.w, names.items, try nametable.build(a, names.items));
        try self.w.writeAll(";\n");
    }

    /// The table of plain enum `ty`'s names (`emitTextTable`).
    fn writeTextTable(self: *Emitter, ty: TypeId) Error!void {
        const decl = self.facts.nominalDecl(ty) orelse return self.unsupported(.nil, "the names of a type that is no enum");
        if (decl.facts.isBuiltinEnum(decl.sym)) return self.w.print("__rig_text_{s}", .{decl.symbol().name});
        try self.emitTypeTy(ty);
        try self.w.writeAll(".__rig_text");
    }

    /// `(generic_enum Name (T...) variants... methods...)`.
    fn emitGenericEnum(self: *Emitter, node: Sexp) Error!void {
        const members = ir.GenericEnum.members(node);
        const prev = try self.enterNominal(ir.GenericEnum.name(node), true, members);
        defer self.nominal = prev;
        try self.emitGenericHead(ir.GenericEnum.tparams(node), "union(enum)");
        try self.emitUnionVariants(2);
        try self.emitRigName(2);
        try self.emitOwnApis(2);
        try self.emitMethods(members, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v...)` → a Zig error set of its members' Zig names
    /// (`writeErrorName`).
    fn emitErrorSet(self: *Emitter, node: Sexp) Error!void {
        const set = self.srcText(ir.Errors.name(node));
        try self.w.print("pub const {f} = error{{\n", .{ident(set)});
        for (ir.Errors.members(node)) |v| {
            const name = if (v == .src) v else if (v.isKind(.variant)) ir.Variant.name(v) else continue;
            try self.w.writeAll("    ");
            try writeErrorName(self.w, self.facts, set, self.srcText(name));
            try self.w.writeAll(",\n");
        }
        try self.w.writeAll("};\n");
        // Each member with fields: the struct of them, which its value's
        // data holds (`rig.ErrorValue`).
        const sym = self.facts.symbolOf(ir.Errors.name(node)) orelse return;
        for (self.facts.symbols.items[sym].fields orelse &.{}) |f| {
            const payload = f.payload orelse continue;
            if (!f.is_variant or payload.len == 0) continue;
            try self.w.print("pub const {f} = struct {{\n", .{ident(try self.fmt("{s}__{s}", .{ set, f.name }))});
            for (payload) |p| {
                try self.w.print("    {f}: ", .{ident(p.name)});
                try self.emitTypeTy(p.ty);
                try self.w.writeAll(",\n");
            }
            try self.w.writeAll("};\n");
        }
    }

    /// Whether a value of `ty` is a `rig.ErrorValue`: `error`, or of a set
    /// with a member with fields, or a union of one. (With no field in
    /// the program, an `ErrorValue` is its code.)
    fn isErrorValueTy(self: *Emitter, ty: TypeId) bool {
        return self.facts.isErrorValueForm(ty);
    }

    /// The struct of the fields of member `member` of error set `set`, as
    /// this module names it.
    fn emitMemberFieldsTy(self: *Emitter, set: TypeId, member: []const u8) Error!void {
        const decl = self.facts.nominalDecl(set) orelse return self.unsupported(.nil, "an error of no set");
        const name = try self.fmt("{s}__{s}", .{ decl.symbol().name, member });
        if (decl.module_id) |m| {
            try self.writeModuleRef(m);
            return self.w.print(".{f}", .{ident(name)});
        }
        try self.w.print("{f}", .{ident(name)});
    }

    /// `error L = A | B`: the Zig sets merged, `A || B`.
    fn emitErrorJoin(self: *Emitter, node: Sexp) Error!void {
        const sym = self.facts.symbolOf(ir.ErrorJoin.name(node)) orelse return self.unsupported(node, "an unresolved union of error sets");
        try self.w.print("pub const {f} = ", .{ident(self.srcText(ir.ErrorJoin.name(node)))});
        const parts = self.facts.symbols.items[sym].error_parts orelse &.{};
        // Each part is its set of codes, whether or not a member has fields.
        const saved = self.error_codes;
        defer self.error_codes = saved;
        self.error_codes = true;
        if (parts.len == 0) try self.w.writeAll("error{}");
        for (parts, 0..) |part, i| {
            if (i > 0) try self.w.writeAll(" || ");
            try self.emitTypeTy(part);
        }
        try self.w.writeAll(";\n");
    }

    /// Member `name` of error set `set` as a Zig error value.
    fn writeError(self: *Emitter, set: TypeId, name: []const u8, at: Sexp) Error!void {
        const decl = self.facts.nominalDecl(set) orelse return self.unsupported(at, "an error of no error set");
        try self.w.writeAll("error.");
        try writeErrorName(self.w, decl.facts, decl.symbol().name, name);
    }

    /// A member without fields, `E.name`, as a value: the Zig error where
    /// the function fails with it or its type is a set of codes, else a
    /// `rig.ErrorValue` holding no fields.
    fn writeErrorMemberValue(self: *Emitter, set: TypeId, name: []const u8, at: Sexp) Error!void {
        const failing = self.fun.has_out and self.facts.isFailingLeaf(at);
        if (failing or self.error_codes or !self.isErrorValueTy(set)) return self.writeError(set, name, at);
        try self.w.writeAll("rig.ErrorValue.of(");
        try self.writeError(set, name, at);
        try self.w.writeAll(", .{})");
    }

    /// Whether `sexp` is an error that may carry fields, a `rig.ErrorValue`;
    /// an error of a set without them is its code alone.
    fn holdsErrorValue(self: *Emitter, sexp: Sexp) bool {
        const ty = self.typeOf(sexp) orelse return false;
        return self.isErrorValueTy(self.peelViews(ty));
    }

    /// `holdsErrorValue`, or an optional of an error value.
    fn holdsErrorValueOpt(self: *Emitter, sexp: Sexp) bool {
        const ty = self.typeOf(sexp) orelse return false;
        return self.isErrorValueTy(self.unwrapOptionals(self.peelViews(ty)));
    }

    /// Whether `sexp` names an error member, `E.name` or `E.name(fields)`,
    /// which emit writes as what the function fails with itself.
    fn namesErrorMember(self: *Emitter, sexp: Sexp) bool {
        if (sexp.isKind(.enum_lit) or self.facts.isErrorMember(sexp)) return true;
        if (!sexp.isKind(.call)) return false;
        const callee = ir.Call.callee(sexp);
        return callee.isKind(.member) and self.facts.typeOf(callee) == null;
    }

    fn enterNominal(self: *Emitter, name_node: Sexp, generic: bool, members: []const Sexp) Error!?Nominal {
        const prev = self.nominal;
        const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved type");
        const name = if (generic) "__rig_Self" else try self.fmt("{f}", .{ident(self.srcText(name_node))});
        var methods: std.ArrayList([]const u8) = .empty;
        for (members) |m| if (m.isKind(.fun) or m.isKind(.sub)) {
            try methods.append(self.arena.allocator(), try self.fmt("{f}", .{ident(self.srcText(ir.get(m, .name)))}));
        };
        self.nominal = .{ .name = name, .sym = sym, .members = members, .methods = methods.items };
        return prev;
    }

    /// `pub fn Name(comptime T: type, comptime n: i64, ...) type { return
    /// <container> {`. Its name (`emitRigName`) names every parameter.
    fn emitGenericHead(self: *Emitter, params: Sexp, container: []const u8) Error!void {
        try self.w.print("pub fn {f}(", .{ident(self.facts.symbols.items[self.nominal.?.sym].name)});
        for (params.items(), 0..) |p, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.w.print("comptime {f}: ", .{ident(facts.syntax.paramName(self.source, p).?)});
            if (p == .src) {
                try self.w.writeAll("type");
                if (self.facts.symbolOf(p)) |sym| try self.writeWitnessParams(sym);
            } else try self.emitTypeTy(try self.declType(ir.get(p, .name)));
        }
        try self.w.writeAll(") type {\n");
        for (params.items()) |p| if (p == .src) if (self.facts.symbolOf(p)) |sym| try self.discardWitnesses(sym, 1);
        try self.w.print("    return {s} {{\n        const __rig_Self = @This();\n\n", .{container});
    }

    // -------------------------------------------------------------------------
    // APIs of a program's own: witnesses (docs/design/apis.md, Stage 3)
    // -------------------------------------------------------------------------

    /// `api Shape`: its defaults, each a method generic over `Self`, the
    /// type that provides the API, and that type's witness, through which
    /// the body calls the API's methods: `pub fn __rig_defaults_Shape(comptime
    /// Self: type, comptime W_Self_Shape: type) type`. A witness names each
    /// default it takes (`emitWitness`). An API without defaults writes
    /// nothing.
    fn emitApi(self: *Emitter, node: Sexp) Error!void {
        const name_node = ir.Api.name(node);
        const id = self.facts.symbolOf(name_node) orelse return self.unsupported(name_node, "an unresolved API");
        const sym = self.facts.symbols.items[id];
        try self.emitApiTable(id, sym);
        var defaults: std.ArrayList(Sexp) = .empty;
        for (ir.rest(node, .members)) |m| {
            if ((m.isKind(.fun) or m.isKind(.sub)) and ir.get(m, .body) != .nil) try defaults.append(self.arena.allocator(), m);
        }
        if (defaults.items.len == 0) return;
        const self_param = (sym.type_params orelse return self.unsupported(name_node, "an API without its `Self`"))[0];
        const prev = try self.enterNominal(name_node, false, defaults.items);
        defer self.nominal = prev;
        try self.w.print("pub fn __rig_defaults_{s}(comptime Self: type", .{sym.name});
        try self.writeWitnessParams(self_param);
        try self.w.writeAll(") type {\n");
        try self.discardWitnesses(self_param, 1);
        try self.w.writeAll("    return struct {\n");
        try self.emitMethods(defaults.items, 2);
        try self.w.writeAll("    };\n}\n");
    }

    /// `api Shape`'s table (docs/design/apis.md, Stage 4): a struct of a
    /// function pointer per method a call through an object reaches
    /// (`sema.TableEntry`), `pub const __rig_table_Shape = struct`, and
    /// the function that gives the table of type `T` and its witness `W`,
    /// `__rig_table_Shape_of(T, W, holding)`, whose entries each call the
    /// witness's method on the value the object holds, self given as the
    /// method takes it, and whose drop, clone, and weak entries are the
    /// holding's (`rig.ApiHolding`). Zig makes one table per API, type,
    /// and holding, and only where a conversion names it. Every name it
    /// declares is hidden (`__rig_T`, `__rig_W`, `__rig_H`,
    /// `__rig_entry_area`), so none shadows or meets a declaration of the
    /// module's own (`fun area`, `type T`), and every entry it holds
    /// beside the API's methods is `__rig_` and a word, which no method
    /// is named.
    fn emitApiTable(self: *Emitter, id: SymbolId, sym: facts.Symbol) Error!void {
        const entries = self.facts.objectTable(id);
        try self.w.print("pub const __rig_table_{s} = struct {{\n", .{sym.name});
        for (entries) |e| {
            if (!tableHolds(e)) continue;
            try self.w.print("    {f}: *const fn (", .{ident(e.name)});
            try self.writeEntrySignature(e, false);
            try self.w.writeAll(",\n");
        }
        // How the value prints, read only where the braces or the API
        // name `Print`; how a box of it is dropped, and cloned where the
        // braces name `Clone`, or a count of it given back and added; and
        // the weak count of a `*{A}`, made, given back, and upgraded.
        try self.w.writeAll("    __rig_print: rig.ErasedPrint,\n");
        try self.w.writeAll("    __rig_drop: rig.ErasedDrop,\n");
        try self.w.writeAll("    __rig_clone: rig.ErasedClone,\n");
        try self.w.writeAll("    __rig_weak: rig.ErasedWeak,\n");
        try self.w.writeAll("    __rig_weak_drop: rig.ErasedWeak,\n");
        try self.w.writeAll("    __rig_upgrade: rig.ErasedUpgrade,\n");
        // The API's name, for `$name` of an object's type (`rig.typeName`).
        try self.w.print("\n    pub const __rig_name = .{{ .module = \"{s}\", .name = \"{s}\" }};\n", .{ nameModule(self.facts), sym.name });
        try self.w.writeAll("};\n\n");
        try self.w.print("pub fn __rig_table_{s}_of(comptime __rig_T: type, comptime __rig_W: type, comptime __rig_H: rig.ApiHolding) *const __rig_table_{s} {{\n", .{ sym.name, sym.name });
        try self.w.writeAll("    return &struct {\n");
        try self.w.print("        const __rig_table: __rig_table_{s} = .{{", .{sym.name});
        var n: usize = 0;
        for (entries) |e| {
            if (!tableHolds(e)) continue;
            try self.w.print(" .{f} = __rig_entry_{s},", .{ ident(e.name), e.name });
            n += 1;
        }
        try self.w.writeAll(" .__rig_print = rig.printErased(__rig_T), .__rig_drop = rig.dropErased(__rig_T, __rig_H), .__rig_clone = rig.cloneErased(__rig_T, __rig_H), .__rig_weak = rig.weakErased(__rig_T, __rig_H), .__rig_weak_drop = rig.weakDropErased(__rig_T, __rig_H), .__rig_upgrade = rig.upgradeErased(__rig_T, __rig_H) };\n");
        if (n == 0) try self.w.writeAll("        comptime {\n            _ = @TypeOf(__rig_W);\n        }\n");
        for (entries) |e| {
            if (!tableHolds(e)) continue;
            const f = self.facts.types.get(e.fn_ty).function;
            const args = f.params[@min(1, f.params.len)..];
            try self.w.print("        fn __rig_entry_{s}(", .{e.name});
            try self.writeEntrySignature(e, true);
            try self.w.writeAll(" {\n");
            // A method that consumes self takes the value out of the box,
            // whose memory is freed first: the entry owns nothing after,
            // so a method that fails drops self once, as its own.
            if (e.self_mode == .value) {
                try self.w.writeAll("            var __rig_self = rig.erasedTake(__rig_T, __rig_ptr);\n            const __rig_p = &__rig_self;\n");
            } else try self.w.print("            const __rig_p = rig.erasedSelf({s}__rig_T, __rig_ptr);\n", .{if (e.self_mode == .write) "*" else "*const "});
            try self.w.writeAll("            return ");
            const call = try self.fmt("__rig_W.{f}(rig.selfArg(__rig_W.{f}, __rig_p){s}", .{ ident(e.name), ident(e.name), if (args.len > 0) ", " else "" });
            var list: std.ArrayList(u8) = .empty;
            for (0..args.len) |i| try list.print(self.arena.allocator(), "{s}__rig_a{d}", .{ if (i > 0) ", " else "", i });
            // A fallible method's entry takes the slot, and passes it on
            // to a method that takes one (`rig.takesSlot`).
            if (self.facts.types.get(f.returns) == .fallible) {
                try self.w.print("if (comptime rig.takesSlot(__rig_W.{f}, {d})) {s}{s}, __rig_out) else {s}{s});\n", .{ ident(e.name), args.len + 1, call, list.items, call, list.items });
            } else try self.w.print("{s}{s});\n", .{ call, list.items });
            try self.w.writeAll("        }\n");
        }
        try self.w.print("    }}.__rig_table;\n}}\n\n", .{});
    }

    /// Whether an API's table holds an entry for `e`: a method that takes
    /// self, lent to read or to write, or consumed, which only a box
    /// gives (docs/design/apis.md, Stage 4).
    fn tableHolds(e: facts.TableEntry) bool {
        return e.self_mode != .none;
    }

    /// A table entry's parameters and result: the address of the value,
    /// then the method's parameters after self, the slot of a fallible
    /// method, and its result; `named` writes the names an entry's body
    /// reads.
    fn writeEntrySignature(self: *Emitter, e: facts.TableEntry, named: bool) Error!void {
        const f = self.facts.types.get(e.fn_ty).function;
        if (named) try self.w.writeAll("__rig_ptr: ");
        try self.w.writeAll(switch (e.self_mode) {
            .write => "rig.ErasedWrite",
            .value => "rig.ErasedOwn",
            else => "rig.ErasedRead",
        });
        for (f.params[@min(1, f.params.len)..], 0..) |p, i| {
            try self.w.writeAll(", ");
            if (named) try self.w.print("__rig_a{d}: ", .{i});
            try self.emitTypeTy(p);
        }
        if (self.facts.types.get(f.returns) == .fallible) try self.w.writeAll(if (named) ", __rig_out: rig.ErrSlot" else ", rig.ErrSlot");
        try self.w.writeAll(") ");
        if (f.is_sub and f.returns == self.facts.types.void_id) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
    }

    /// `__rig_table_Shape`, or another module's `geo.__rig_table_Shape`:
    /// the table of API `api`.
    fn writeTableName(self: *Emitter, api: facts.ApiRef) Error!void {
        const sym = self.facts.apiSymbol(api) orelse return self.unsupported(.nil, "an API object of an unknown API");
        if (api.module_id != self.facts.moduleId()) {
            try self.writeModuleRef(api.module_id);
            try self.w.writeAll(".");
        }
        try self.w.print("__rig_table_{s}", .{sym.name});
    }

    /// The witness parameters of type parameter `sym`, after its own: one
    /// for each API of a program's own its bounds name, `, comptime
    /// W_T_Shape: type`.
    fn writeWitnessParams(self: *Emitter, sym: SymbolId) Error!void {
        for (self.facts.symbols.items[sym].user_apis) |api| try self.w.print(", comptime {s}: type", .{try self.witnessParamName(sym, api)});
    }

    /// Type parameter `sym`'s witnesses, which a body may not call
    /// through: read by their type, so Zig finds each used and none
    /// discarded in vain.
    fn discardWitnesses(self: *Emitter, sym: SymbolId, depth: u32) Error!void {
        for (self.facts.symbols.items[sym].user_apis) |api| {
            try self.writeIndent(depth);
            try self.w.print("_ = @TypeOf({s});\n", .{try self.witnessParamName(sym, api)});
        }
    }

    /// The witness parameters of the method named at `name_node` when it
    /// is declared under bounds on its type's parameters
    /// (`Field.owner_bounds`): `W_T_Shape` for each API of a program's own
    /// they name, in order.
    fn ownerWitnessParams(self: *Emitter, name_node: Sexp) Error![]const []const u8 {
        const nom = self.nominal orelse return &.{};
        if (name_node != .src or nom.sym == facts.symbol_invalid) return &.{};
        const sym = self.facts.symbols.items[nom.sym];
        const tparams = sym.type_params orelse return &.{};
        const field = for (sym.fields orelse return &.{}) |f| {
            if (f.is_method and f.decl_pos == name_node.src.pos) break f;
        } else return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (field.owner_bounds) |b| {
            if (b.param >= tparams.len) return self.unsupported(name_node, "a bound on a parameter its type does not have");
            for (b.user_apis) |api| try out.append(self.arena.allocator(), try self.witnessParamName(tparams[b.param], api));
        }
        return out.items;
    }

    /// `W_T_Shape`: type parameter `sym`'s witness for `api`.
    fn witnessParamName(self: *Emitter, sym: SymbolId, api: facts.ApiRef) Error![]const u8 {
        if (self.facts.apiSymbol(api) == null) return self.unsupported(.nil, "a bound by an unknown API");
        return self.facts.witnessParamName(self.arena.allocator(), sym, api);
    }

    /// A witness as a compile-time argument: a type parameter's own,
    /// `W_T_Shape`, or a conformance's namespace, `__rig_impl_Shape_Square`,
    /// another module's through that module, and a generic type's applied
    /// to its arguments and their witnesses.
    fn writeWitness(self: *Emitter, w: facts.Witness) Error!void {
        switch (w) {
            .param => |p| try self.w.writeAll(try self.witnessParamName(p.sym, p.api)),
            .conformance => |c| {
                if (c.module_id != self.facts.moduleId()) {
                    try self.writeModuleRef(c.module_id);
                    try self.w.writeAll(".");
                }
                try self.w.writeAll(try self.facts.witnessName(self.arena.allocator(), c.module_id, c.index));
                const found = self.facts.conformanceAt(c.module_id, c.index) orelse return self.unsupported(.nil, "a witness of an unknown conformance");
                switch (found.facts.types.get(found.conf.ty)) {
                    .parameterized_nominal, .slot => {},
                    else => return,
                }
                const args = try self.facts.conformanceArgs(self.arena.allocator(), c.ty);
                if (args.len == 0) return self.unsupported(.nil, "a generic type's witness for another type");
                try self.w.writeAll("(");
                try self.writeArgsWithWitnesses(args, c.args);
                try self.w.writeAll(")");
            },
        }
    }

    /// Type arguments `args`, each followed by the witnesses `ws` give it.
    fn writeArgsWithWitnesses(self: *Emitter, args: []const TypeId, ws: []const facts.ArgWitness) Error!void {
        for (args, 0..) |arg, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitTypeTy(arg);
            for (ws) |aw| if (aw.arg == i) {
                try self.w.writeAll(", ");
                try self.writeWitness(aw.witness);
            };
        }
    }

    /// The arguments of `ty`, an instance of generic type `sym`: with the
    /// witnesses its bounds take, so one Rig type is one Zig type.
    fn emitTypeArgs(self: *Emitter, ty: TypeId, sym: SymbolId, args: []const TypeId) Error!void {
        if (!self.facts.takesWitnesses(sym)) return self.emitTypeList(args);
        const ws = self.facts.typeWitnesses(ty) orelse return self.unsupported(.nil, "an instance of a generic type whose witnesses no check recorded");
        try self.writeArgsWithWitnesses(args, ws);
    }

    /// The witness of each conformance this module writes: a namespace
    /// declared beside it, `__rig_impl_Shape_Square`, whose members name
    /// the type's methods, an addition's methods, and the defaults it
    /// takes. A generic type's, or an addition's under a bound, is a
    /// function of the type's arguments and the witnesses its bounds ask
    /// for.
    fn emitWitnesses(self: *Emitter) Error!void {
        for (self.facts.conformances(), 0..) |conf, i| try self.emitWitness(conf, @intCast(i));
    }

    fn emitWitness(self: *Emitter, conf: facts.Conformance, index: u32) Error!void {
        const a = self.arena.allocator();
        const name = try self.facts.witnessName(a, self.facts.moduleId(), index);
        const params = self.witnessTypeParams(conf);
        try self.w.writeAll("\n");
        if (params.len > 0) {
            try self.w.print("pub fn {s}(", .{name});
            for (params, 0..) |p, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.w.print("comptime {f}: ", .{ident(self.facts.symbols.items[p].name)});
                // A compile-time value parameter (`Grid[n: Int, T]`) has
                // its type; a type parameter is a type, with its witnesses.
                if (self.facts.symbols.items[p].kind != .generic_param) {
                    try self.emitTypeTy(self.symType(p) orelse return self.unsupported(.nil, "an untyped compile-time parameter"));
                    continue;
                }
                try self.w.writeAll("type");
                try self.writeWitnessParams(p);
            }
            try self.w.writeAll(") type {\n");
            for (params) |p| {
                try self.w.print("    _ = @TypeOf({f});\n", .{ident(self.facts.symbols.items[p].name)});
                try self.discardWitnesses(p, 1);
            }
            try self.w.writeAll("    return struct {\n");
        } else try self.w.print("pub const {s} = struct {{\n", .{name});
        const depth: u32 = if (params.len > 0) 2 else 1;
        // What it gives each associated type, which a body bounded by the
        // API names through the witness (`W_S_Source.Item`).
        for (conf.assoc) |b| {
            if (b.ty == facts.type_invalid) return self.unsupported(.nil, "an associated type no method gives");
            try self.writeIndent(depth);
            try self.w.print("pub const {f} = ", .{ident(b.name)});
            try self.emitTypeTy(b.ty);
            try self.w.writeAll(";\n");
        }
        // The first conformance an addition writes holds its methods, those
        // only the addition's other APIs declare included; the others name
        // them there.
        const first: u32 = for (self.facts.conformances(), 0..) |c, i| {
            if (c.kind == .add and c.pos == conf.pos) break @intCast(i);
        } else index;
        if (conf.kind == .add and first == index) {
            var written: std.ArrayList([]const u8) = .empty;
            for (self.facts.conformances()) |c| {
                if (c.kind != .add or c.pos != conf.pos) continue;
                for (c.members) |m| {
                    if (m.from != .added) continue;
                    const seen = for (written.items) |n| {
                        if (std.mem.eql(u8, n, m.name)) break true;
                    } else false;
                    if (seen) continue;
                    try written.append(a, m.name);
                    const node = self.additionMethod(conf.pos, m.name) orelse return self.unsupported(.nil, "an addition's method without its declaration");
                    try self.emitAddedMethod(conf, node, depth);
                }
            }
        }
        for (conf.members) |m| switch (m.from) {
            .own => {
                try self.writeIndent(depth);
                try self.w.print("pub const {f} = ", .{ident(m.name)});
                try self.emitTypeTy(conf.ty);
                try self.w.print(".{f};\n", .{ident(m.name)});
            },
            .added => if (first != index) {
                try self.writeIndent(depth);
                try self.w.print("pub const {f} = {s}", .{ ident(m.name), try self.facts.witnessName(a, self.facts.moduleId(), first) });
                if (params.len > 0) {
                    try self.w.writeAll("(");
                    for (params, 0..) |p, i| {
                        if (i > 0) try self.w.writeAll(", ");
                        try self.w.print("{f}", .{ident(self.facts.symbols.items[p].name)});
                        for (self.facts.symbols.items[p].user_apis) |api| try self.w.print(", {s}", .{try self.witnessParamName(p, api)});
                    }
                    try self.w.writeAll(")");
                }
                try self.w.print(".{f};\n", .{ident(m.name)});
            },
            .default => |api| {
                try self.writeIndent(depth);
                try self.w.print("pub const {f} = ", .{ident(m.name)});
                if (api.module_id != self.facts.moduleId()) {
                    try self.writeModuleRef(api.module_id);
                    try self.w.writeAll(".");
                }
                const api_sym = self.facts.apiSymbol(api) orelse return self.unsupported(.nil, "a default of an unknown API");
                try self.w.print("__rig_defaults_{s}(", .{api_sym.name});
                try self.emitTypeTy(conf.ty);
                try self.w.print(", @This()).{f};\n", .{ident(m.name)});
            },
        };
        try self.w.writeAll(if (params.len > 0) "    };\n}\n" else "};\n");
    }

    /// The type parameters a witness takes: a generic type's, for a
    /// header, or an addition's own.
    fn witnessTypeParams(self: *Emitter, conf: facts.Conformance) []const SymbolId {
        if (conf.kind == .add) return conf.params;
        return switch (self.facts.types.get(conf.ty)) {
            .parameterized_nominal => |pn| self.facts.symbols.items[pn.sym].type_params orelse &.{},
            else => &.{},
        };
    }

    /// The method `name` of the addition written at `pos`.
    fn additionMethod(self: *Emitter, pos: u32, name: []const u8) ?Sexp {
        for (self.additions.items) |add| {
            if (self.facts.startOf(add) != pos) continue;
            for (ir.rest(add, .members)) |m| {
                if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
                if (std.mem.eql(u8, self.srcText(ir.get(m, .name)), name)) return m;
            }
        }
        return null;
    }

    /// An addition's method, in its witness: a method of the type it adds
    /// the API to, `@` a view of that type.
    fn emitAddedMethod(self: *Emitter, conf: facts.Conformance, node: Sexp, depth: u32) Error!void {
        const prev = self.nominal;
        defer self.nominal = prev;
        self.nominal = .{ .name = "@This()", .sym = conf.self_sym, .members = &.{node}, .methods = &.{try self.fmt("{f}", .{ident(self.srcText(ir.get(node, .name)))})} };
        try self.emitMethods(&.{node}, depth);
    }

    /// `x.area()` or `Shape.area(x)` through a witness: `W.area(self,
    /// args)`, self given as the method takes it (`emitWitnessSelf`).
    fn emitWitnessCall(self: *Emitter, call: Sexp, s: facts.Dispatch.Static) Error!void {
        try self.writeWitnessMethod(s);
        try self.w.writeAll("(");
        if (!s.receiver_arg) {
            const recv = self.receiverOf(call) orelse return self.unsupported(call, "a call through a witness without its receiver");
            try self.emitWitnessSelf(call, recv, s);
            // `emitArgs` writes the separators between what it writes.
            const slots = self.facts.callSlotsOf(call);
            const runtime = if (slots) |sl| sl.len else ir.Call.args(call).len;
            const slot = if (self.fail_slot) |f| sameNode(f.call, call) else false;
            if (runtime > 0 or ctArgCount(self.facts.genericCallOf(call), self.facts.ctArgsOf(call)) > 0 or slot) try self.w.writeAll(", ");
            try self.emitArgs(call);
        } else try self.emitArgs(call);
        try self.w.writeAll(")");
    }

    /// `s.area(args)` or `Shape.area(s, args)` through an API object's
    /// table (docs/design/apis.md, Stage 4): `s.vt.area(s.ptr, args)`, the
    /// slot a `!` or `catch` lends after the arguments of a fallible
    /// method. A receiver other than a name is evaluated once, into a
    /// constant of the call's own block.
    fn emitObjectCall(self: *Emitter, call: Sexp, d: facts.Dispatch.Dynamic) Error!void {
        const recv_node = if (d.receiver_arg) ir.Call.args(call)[0] else self.receiverOf(call) orelse return self.unsupported(call, "a call through an API object without its receiver");
        const recv = lentPlace(recv_node);
        var buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved = self.w;
            self.w = &buf.writer;
            defer self.w = saved;
            try self.emitExpr(recv);
        }
        const direct = recv == .src;
        const id = self.nextId();
        const name = if (direct) buf.written() else try self.fmt("__rig_obj_{d}", .{id});
        if (!direct) try self.w.print("(__rig_call_{d}: {{ const {s} = {s}; break :__rig_call_{d} ", .{ id, name, buf.written(), id });
        try self.w.print("{s}.vt.{f}({s}.ptr", .{ name, ident(d.method), name });
        const skip: usize = @intFromBool(d.receiver_arg);
        const slots = self.facts.callSlotsOf(call);
        const runtime = (if (slots) |sl| sl.len else ir.Call.args(call).len) -| skip;
        const slot = if (self.fail_slot) |f| sameNode(f.call, call) else false;
        if (runtime > 0 or slot) try self.w.writeAll(", ");
        try self.emitArgsFrom(call, skip);
        try self.w.writeAll(")");
        if (!direct) try self.w.writeAll("; })");
    }

    /// `W.area`: the method of the witness a call reaches.
    fn writeWitnessMethod(self: *Emitter, s: facts.Dispatch.Static) Error!void {
        try self.writeWitness(s.witness);
        try self.w.print(".{f}", .{ident(s.method)});
    }

    /// The self of a call through a witness: a value it consumes, moved
    /// in; otherwise the receiver's address, which `rig.selfArg` gives as
    /// the method takes self, a pointer or a copy.
    fn emitWitnessSelf(self: *Emitter, call: Sexp, recv: Sexp, s: facts.Dispatch.Static) Error!void {
        if (s.self_mode == .value) return self.emitExpr(recv);
        try self.w.writeAll("rig.selfArg(");
        try self.writeWitnessMethod(s);
        try self.w.writeAll(", ");
        _ = call;
        try self.emitReceiverAddress(recv, s);
        try self.w.writeAll(")");
    }

    /// The address of the receiver of a call through a witness, or of the
    /// view it is, as a task's method receiver is given (`emitTask`).
    fn emitReceiverAddress(self: *Emitter, recv: Sexp, s: facts.Dispatch.Static) Error!void {
        const saved = self.read_place;
        defer self.read_place = saved;
        self.read_place = s.self_mode != .write;
        try self.emitAddressOf(lentPlace(recv));
    }

    /// The fields and variants of the nominal type being emitted, in
    /// declaration order.
    fn nominalFields(self: *Emitter) []const facts.Field {
        return self.facts.symbols.items[self.nominal.?.sym].fields orelse &.{};
    }

    /// `pub const __rig_name = .{ .module = "geo", .name = .{ "Point" } };`:
    /// the type being emitted as sema's printer spells it, for `$name` of
    /// a type parameter (`rig.typeName`): its module (`nameModule`), and
    /// its spelling, a generic type's at the parameters of each instance
    /// (`.{ "Pair[", A, ", ", B, "]" }`).
    /// The runtime's hooks into the methods by which the type being
    /// emitted gives `==`, hashing, ordering, or printing a meaning of its
    /// own (docs/design/apis.md, Stage 2): `rig.eql`, `rig.hash`,
    /// `rig.order`, and `print` call them for the type, and for it as a
    /// part of another value, at every level.
    fn emitOwnApis(self: *Emitter, depth: u32) Error!void {
        const sym = self.facts.symbols.items[self.nominal.?.sym];
        const view = "rig.viewOf(@This(), a), rig.viewOf(@This(), b)";
        if (facts.syntax.ownApiMethod(sym, .Eq) != null) {
            try self.writeIndent(depth);
            try self.w.print("pub fn __rig_own_eq(a: *const @This(), b: *const @This()) bool {{ return @This().eq({s}); }}\n", .{view});
        }
        if (facts.syntax.ownApiMethod(sym, .Ord) != null) {
            try self.writeIndent(depth);
            try self.w.print("pub fn __rig_own_order(a: *const @This(), b: *const @This()) rig.Order {{ return @This().order({s}); }}\n", .{view});
        }
        if (facts.syntax.ownApiMethod(sym, .Print) != null) {
            try self.writeIndent(depth);
            try self.w.writeAll("pub fn __rig_own_print(a: *const @This(), out: *rig.Printer) void { @This().print(rig.viewOf(@This(), a), out); }\n");
        }
        if (facts.syntax.ownApiMethod(sym, .Hash) != null) {
            try self.writeIndent(depth);
            try self.w.writeAll("pub fn __rig_own_hash(a: *const @This()) u64 { var h: rig.Hasher = .{}; @This().hash_into(rig.viewOf(@This(), a), &h); return h.state; }\n");
        }
    }

    fn emitRigName(self: *Emitter, depth: u32) Error!void {
        const sym = self.nominal.?.sym;
        const a = self.arena.allocator();
        const spelling = if (self.facts.symbols.items[sym].type_params != null)
            try self.facts.formatGenericSelfMarked(a, sym)
        else
            try self.facts.formatTypeValue(a, .{ .nominal = sym });
        try self.writeIndent(depth);
        try self.w.print("pub const __rig_name = .{{ .module = \"{s}\", .name = ", .{nameModule(self.facts)});
        try self.writeSpelling(spelling, .parts, null);
        try self.w.writeAll(" };\n");
        // A table of the type reserves its slots, which the system gives
        // as zeros (`sema.tableFill`, `rig.Table`).
        if (self.facts.declFill(sym) == .zeros) {
            try self.writeIndent(depth);
            try self.w.writeAll("pub const __rig_zeros = true;\n");
        }
    }

    fn emitFields(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |f| {
            if (f.is_method or f.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(f.name)});
            try self.emitTypeTy(f.ty);
            if (f.default) |d| {
                try self.w.writeAll(" = ");
                try self.emitDefault(self.facts, d, f.ty);
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Variants of a tagged union: bare → `void`, a payload → a struct
    /// of its fields.
    fn emitUnionVariants(self: *Emitter, depth: u32) Error!void {
        for (self.nominalFields()) |v| {
            if (!v.is_variant) continue;
            try self.writeIndent(depth);
            try self.w.print("{f}: ", .{ident(v.name)});
            const fields = v.payload orelse &.{};
            if (fields.len == 0) {
                try self.w.writeAll("void");
            } else {
                try self.w.writeAll("struct { ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try self.w.writeAll(", ");
                    try self.w.print("{f}: ", .{ident(f.name)});
                    try self.emitTypeTy(f.ty);
                }
                try self.w.writeAll(" }");
            }
            try self.w.writeAll(",\n");
        }
    }

    /// Methods of a nominal type, and its `drop` body.
    fn emitMethods(self: *Emitter, members: []const Sexp, depth: u32) Error!void {
        for (members) |m| {
            const head = m.kind() orelse continue;
            if (head != .fun and head != .sub and head != .drop_decl) continue;
            try self.w.writeAll("\n");
            try self.writeIndent(depth);
            const prev_indent = self.indent;
            self.indent = depth;
            defer self.indent = prev_indent;
            if (head == .drop_decl) {
                try self.emitDropDecl(m);
            } else {
                try self.emitFun(m);
            }
        }
    }

    /// `(drop_decl params block)`: the body becomes `__rig_user_drop`, and
    /// `__rig_drop` runs it and then drops every field.
    fn emitDropDecl(self: *Emitter, node: Sexp) Error!void {
        const nom = self.nominal.?.name;
        // A large frame is never inlined into `__rig_drop`'s.
        try self.w.print("{s}fn __rig_user_drop(self: *{s}) void ", .{ if (self.facts.isLargeOwner(node)) "noinline " else "", nom });
        const params = ir.DropDecl.params(node);
        self.fun = .{ .params = params };
        try self.pushScope();
        try self.bindParams(params, false);
        try self.emitBlock(ir.DropDecl.body(node));
        try self.popScope();
        try self.w.writeAll("\n\n");
        try self.line("pub fn __rig_drop(self: *{s}) void {{", .{nom});
        try self.line("    self.__rig_user_drop();", .{});
        try self.line("    rig.dropFields(self);", .{});
        try self.line("}}", .{});
    }

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// `(fun name params returns body)` / `(sub name params _ body)`.
    fn emitFun(self: *Emitter, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        const name = self.srcText(name_node);
        const params = ir.get(node, .params);
        const body = ir.get(node, .body);
        const f = self.fnType(self.facts.typeOf(name_node)) orelse return self.unsupported(name_node, "an untyped function");
        // Only the root module's `main` is the program's entry point.
        const is_main = self.facts.is_root and self.nominal == null and std.mem.eql(u8, name, "main");
        const return_ty: ?TypeId = if (f.returns == self.facts.types.void_id) null else f.returns;
        // `main` may fail out of the program (`!`, `sub main()!`, `-> Int!`),
        // and `fun main() -> Int` returns its exit status.
        const main_fails = is_main and (contains(body, &.{.propagate}) or rig.subFails(node) or (return_ty != null and self.facts.types.get(return_ty.?) == .fallible));
        const main_status = is_main and !f.is_sub;

        const tparams = facts.syntax.tparamsOf(node);
        const inlined = self.facts.isInlined(name_node);
        const marker = self.facts.markerOf(node);
        const entry_check = self.yield_checks and self.facts.hasEntryCheck(name_node);
        // A function that always panics is cold, as a `rarely` one is,
        // so a call of it is laid out off the path that does not.
        const cold = marker == .rarely or (marker == .none and !is_main and rig.alwaysPanics(body));
        self.fun = .{ .return_ty = return_ty, .params = params, .tparams = tparams, .leak_check = is_main, .inlined = inlined, .cold = cold, .entry_check = entry_check };
        // `main` holds the slot its failure's fields go in.
        // (A `main` that declares no failure but uses `!` fails with any
        // error.)
        const main_fields = if (return_ty) |r| (if (self.facts.types.get(r) == .fallible) self.failsWithFields(r) else true) else true;
        if (is_main and main_fails and main_fields) {
            self.fun.main_slot = true;
            self.fun.has_out = true;
            self.fun.out_unmarked = true;
        }

        // The runtime's panic handler flushes buffered `print` output first.
        if (is_main) try self.w.writeAll("pub const panic = rig.panic;\n\n");
        // A `main` that can fail is canceled by an interrupt or SIGTERM
        // (`rig.cancelOnInterrupt`); one that cannot keeps their default.
        if (main_fails) try self.w.writeAll("pub const __rig_interrupt = true;\n\n");
        // `main` is the body of a Zig `main` that runs it on the stack the
        // runtime maps (`rig.onOwnStack`), then reports a failure as Rig
        // shows errors (`rig.failMain`) or sets the exit status
        // (`rig.exitStatus`), after every drop and the leak check.
        // A `main` whose failure may carry fields runs its body with the
        // slot they go in (`__rig_fail_main`), which shows the failure and
        // drops them after the body's drops and defers, before `finish`.
        if (self.fun.main_slot) {
            const ret = if (main_status) "u8" else "void";
            try self.w.print("pub fn main(__rig_init: std.process.Init.Minimal) {s} {{\n    return rig.onOwnStack(__rig_fail_main, .{{__rig_init}});\n}}\n\n", .{ret});
            try self.w.print("fn __rig_fail_main(__rig_init: std.process.Init.Minimal) {s} {{\n    var __rig_main_slot: rig.ErrData = undefined;\n", .{ret});
            try self.w.writeAll("    const result = __rig_run_main(__rig_init, rig.failSlot(&__rig_main_slot)) catch |__rig_failed| {\n        rig.reportFailure(__rig_failed, &__rig_main_slot);\n        rig.finish();\n        rig.failMainReported(__rig_failed);\n    };\n    rig.finish();\n");
            try self.w.writeAll(if (main_status) "    return rig.exitStatus(result);\n}\n\n" else "    return result;\n}\n\n");
            try self.w.writeAll("fn __rig_run_main(");
        } else if (is_main) {
            const catches = if (!main_fails) "" else " catch |__rig_failed| rig.failMain(__rig_failed)";
            const run = "rig.onOwnStack(__rig_run_main, .{__rig_init})";
            if (main_status) {
                try self.w.print("pub fn main(__rig_init: std.process.Init.Minimal) u8 {{\n    return rig.exitStatus({s}{s});\n}}\n\n", .{ run, catches });
            } else try self.w.print("pub fn main(__rig_init: std.process.Init.Minimal) void {{\n    {s}{s};\n}}\n\n", .{ run, catches });
            try self.w.writeAll("fn __rig_run_main(");
        } else try self.w.print("pub {s}fn {f}(", .{ if (inlined) "inline " else if (marker == .called or self.facts.isLargeFrame(name_node)) "noinline " else "", ident(name) });
        // Zig hands the arguments and environment only to `main`.
        if (is_main) try self.w.writeAll(if (self.fun.main_slot) "__rig_init: std.process.Init.Minimal, __out: rig.ErrSlot" else "__rig_init: std.process.Init.Minimal");
        try self.pushScope();
        defer self.popScope() catch {};
        // Compile-time parameters come first, after a method's receiver,
        // which Zig's method call syntax needs first.
        try self.bindParams(tparams, false);
        try self.bindParams(params, inlined);
        const rt = params.items();
        const recv: usize = @intFromBool(self.nominal != null and rt.len > 0 and self.isReceiverParam(rt[0]));
        // A method under bounds on its type's parameters takes a witness
        // for each that names an API of a program's own, after self.
        self.fun.owner_witnesses = try self.ownerWitnessParams(name_node);
        var n: usize = 0;
        for ([_][]const Sexp{ rt[0..recv], tparams.items(), rt[recv..] }, 0..) |group, g| {
            if (g == 1) for (self.fun.owner_witnesses) |w| {
                if (n > 0) try self.w.writeAll(", ");
                n += 1;
                try self.w.print("comptime {s}: type", .{w});
            };
            for (group) |p| {
                if (n > 0) try self.w.writeAll(", ");
                n += 1;
                try self.emitParam(p, g == 1);
            }
        }
        // A function that may fail with fields stores them through the
        // slot its caller lends it, last.
        if (!is_main and self.failsWithFields(return_ty)) {
            self.fun.has_out = true;
            self.fun.out_unmarked = true;
            try self.w.writeAll(if (n > 0) ", __out: rig.ErrSlot" else "__out: rig.ErrSlot");
        }
        try self.w.writeAll(") ");
        if (main_fails) {
            // `anyerror!void`, `anyerror!i64`: whether or not `-> Int!` says so.
            try self.w.writeAll("anyerror!");
            try self.emitTypeTy(if (main_status) self.facts.types.int_id else self.facts.types.void_id);
        } else if (return_ty) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        // A `sub` yields no value, even one that may fail (`Void!`).
        if (return_ty != null and !f.is_sub) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
    }

    /// Bind each parameter in the current scope. An owned value (or one
    /// holding a Cell) is copied into a `var` at the top of the body, so
    /// it can be dropped or changed; the Zig parameter then gets a
    /// generated name. An owning `_` is dropped under a hidden name.
    fn bindParams(self: *Emitter, params: Sexp, inlined: bool) Error!void {
        if (params != .list) return;
        for (params.items()) |p| {
            const name_node = facts.syntax.paramNameNode(p) orelse continue;
            const sym = self.facts.symbolOf(name_node) orelse continue;
            const rig_name = self.srcText(name_node);
            // A type parameter, `comptime T: type`, is a name even when
            // it is `_`: the type's name spells it (`emitRigName`).
            if (self.facts.symbols.items[sym].kind == .generic_param) {
                _ = try self.declare(.{ .sym = sym, .zig_name = if (std.mem.eql(u8, rig_name, "_")) try self.fmt("{f}", .{ident(rig_name)}) else "" }, rig_name);
                continue;
            }
            const ty = self.symType(sym) orelse return self.unsupported(p, "an untyped parameter");
            const unused = std.mem.eql(u8, rig_name, "_");
            var local: Local = .{ .sym = sym, .ty = ty };
            if (!self.isPtrViewTy(ty)) local.kind = self.holdOf(sym);
            if (local.kind != null) {
                local.guard = self.resourceGuard(sym);
                if (unused) local.zig_name = try self.fresh("__rig_unused");
            }
            if (local.kind == .value or local.kind == .optional) {
                local.param_name = try self.fmt("__rig_arg_{d}", .{self.nextId()});
            } else if (inlined and !unused) {
                // Self, `@`, comes in as `__rig_in_self`, so a
                // parameter named `self` takes a number.
                local.param_name = if (std.mem.eql(u8, rig_name, "@"))
                    "__rig_in_self"
                else if (std.mem.eql(u8, rig_name, "self"))
                    try self.fmt("__rig_in_{d}", .{self.nextId()})
                else
                    try self.fmt("__rig_in_{s}", .{rig_name});
                local.launder = true;
            }
            _ = try self.declare(local, rig_name);
        }
    }

    /// `name: T` in a signature; `comptime` for a compile-time parameter,
    /// and `comptime T: type` for a type parameter.
    fn emitParam(self: *Emitter, p: Sexp, ct: bool) Error!void {
        const local = self.localOf(facts.syntax.paramNameNode(p).?).?;
        const name = if (local.param_name.len > 0) local.param_name else local.zig_name;
        try self.w.print("{s}{s}: ", .{ if (ct) "comptime " else "", name });
        if (self.facts.symbols.items[local.sym].kind == .generic_param) {
            try self.w.writeAll("type");
            return self.writeWitnessParams(local.sym);
        }
        try self.emitTypeTy(local.ty.?);
    }

    /// A method's self: `?@`, `!@`, or `<@`.
    fn isReceiverParam(self: *Emitter, p: Sexp) bool {
        return std.mem.eql(u8, facts.syntax.paramName(self.source, p) orelse "", "@");
    }

    /// Statements at the top of a function body: the cold hint of a
    /// `rarely` function, then the evaluation budget
    /// (`rig.eval_quota`) unless it is inline; in `main`,
    /// `rig.start` and the deferred `rig.finish()` (flush output,
    /// check for leaks), then parameter copies and guards, and discards
    /// for unused parameters.
    fn emitFunPrologue(self: *Emitter) Error!void {
        // Zig charges every inline call, ours and the runtime's alike, and
        // every compile-time loop in an inlined body, to one budget per
        // function it emits code for, shared with all the inline calls in
        // it; an inline function's body runs on its caller's. So every
        // function that is not inline raises its budget first.
        if (self.fun.quota) {
            self.fun.quota = false;
            if (self.fun.cold) try self.line("@branchHint(.cold);", .{});
            if (!self.fun.inlined) try self.line("@setEvalBranchQuota(rig.eval_quota);", .{});
            if (self.fun.entry_check) try self.line("rig.tickCall();", .{});
        }
        if (self.fun.leak_check) {
            self.fun.leak_check = false;
            try self.line("rig.start(__rig_init);", .{});
            if (!self.fun.main_slot) try self.line("defer rig.finish();", .{});
        }
        if (self.fun.out_unmarked) {
            self.fun.out_unmarked = false;
            try self.line("_ = &{s};", .{self.fun.out_name});
        }
        if (self.fun.unused_env.len > 0) {
            try self.line("_ = {s};", .{self.fun.unused_env});
            self.fun.unused_env = "";
        }
        const tparams = self.fun.tparams;
        self.fun.tparams = .nil;
        const params = self.fun.params orelse Sexp.nil;
        self.fun.params = null;
        for ([_]Sexp{ tparams, params }) |group| for (group.items()) |p| {
            const local = self.localOf(facts.syntax.paramNameNode(p) orelse continue) orelse continue;
            try self.bindParamLocal(local);
        };
        for (tparams.items()) |p| {
            const local = self.localOf(facts.syntax.paramNameNode(p) orelse continue) orelse continue;
            try self.discardWitnesses(local.sym, self.indent);
        }
        const owner_ws = self.fun.owner_witnesses;
        self.fun.owner_witnesses = &.{};
        for (owner_ws) |w| try self.line("_ = @TypeOf({s});", .{w});
        // A closure its callee calls at most once marks its environment
        // called: the call owns what the environment held, which the
        // environment drops only when it was never called.
        if (self.fun.once_env.len > 0) {
            try self.line("{s}.__rig_called = true;", .{self.fun.once_env});
            self.fun.once_env = "";
        }
        const once_caps = self.fun.once_caps;
        self.fun.once_caps = &.{};
        for (once_caps) |sym| try self.bindParamLocal(self.localBySym(sym) orelse continue);
    }

    /// A parameter's local, or a capture a closure called once takes,
    /// copied into its binding at the top of the body, and its drop
    /// armed (`emitFunPrologue`).
    fn bindParamLocal(self: *Emitter, local: *Local) Error!void {
        if (local.param_name.len > 0) {
            // Zig analyzes an inlined body at each call, so an argument
            // known at compile time would be known inside; `rig.rt`
            // keeps the arithmetic and the indexing on it checked when
            // the program runs, as in a function that is called.
            if (local.launder) {
                try self.line("const {s} = rig.rt({s});", .{ local.zig_name, local.param_name });
            } else if (self.fun.inlined) {
                try self.line("var {s} = rig.rt({s});", .{ local.zig_name, local.param_name });
            } else try self.line("var {s} = {s};", .{ local.zig_name, local.param_name });
        }
        if (local.guard != .none) {
            try self.writeIndent(self.indent);
            try self.emitGuard(local);
            try self.w.writeAll("\n");
        } else if (!self.usage.used.contains(local.sym) and !std.mem.eql(u8, local.zig_name, "_")) {
            // Zig discards no error by value, so an error, or a value
            // whose type an instance gives (which may be one), is
            // discarded by address.
            const by_address = if (local.ty) |ty| self.isErrorSetTy(ty) or self.facts.containsTypeVar(ty) else false;
            try self.line("_ = {s}{s};", .{ if (by_address) "&" else "", local.zig_name });
        }
    }

    // =========================================================================
    // Scopes and names
    // =========================================================================

    fn pushScope(self: *Emitter) Error!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn popScope(self: *Emitter) Error!void {
        var top = self.scopes.pop() orelse return;
        var i = top.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = top.locals.items[i];
            if (l.shadowed) |prev| {
                self.local_by_sym.putAssumeCapacity(l.sym, prev);
            } else {
                _ = self.local_by_sym.remove(l.sym);
            }
            const uses = self.local_names.getPtr(l.zig_name).?;
            uses.* -= 1;
            if (uses.* == 0) _ = self.local_names.remove(l.zig_name);
        }
        top.locals.deinit(self.allocator);
        for (top.flags.items) |k| _ = self.flag_names.remove(k);
        top.flags.deinit(self.allocator);
    }

    /// Declare `local` in the innermost scope, choosing its Zig name from
    /// `rig_name` unless one is given. Returns the stored entry.
    fn declare(self: *Emitter, local: Local, rig_name: []const u8) Error!*Local {
        if (self.scopes.items.len == 0) try self.pushScope();
        var l = local;
        // A pointer view is held as a pointer wherever it is bound.
        if (l.ty) |t| if (self.isPtrViewTy(t)) {
            l.is_ptr = true;
        };
        if (l.zig_name.len == 0) l.zig_name = try self.zigNameFor(rig_name);
        if (l.guard == .flag and l.flag.len == 0) {
            // Named from the local's Zig name, which no visible local
            // shares, or by a number no name of the program's can be.
            l.flag = if (isPlainIdent(l.zig_name)) try self.fmt("__rig_alive_{s}", .{l.zig_name}) else try self.fmt("__rig_alive_{d}", .{self.nextId()});
        }
        // A field moved out of the local is dropped behind a flag of its
        // own, numbered as no name of the program's can be.
        if (l.kind != null and l.parts.len == 0) {
            const parts = self.facts.fieldMoves(l.sym);
            if (parts.len > 0) {
                const flags = try self.arena.allocator().alloc([]const u8, parts.len);
                for (flags) |*f| f.* = try self.fmt("__rig_part_{d}", .{self.nextId()});
                l.parts = parts;
                l.part_flags = flags;
            }
        }
        const scope: u32 = @intCast(self.scopes.items.len - 1);
        const top = &self.scopes.items[scope];
        const ref: LocalRef = .{ .scope = scope, .index = @intCast(top.locals.items.len) };
        const latest = try self.local_by_sym.getOrPut(self.allocator, l.sym);
        l.shadowed = if (latest.found_existing) latest.value_ptr.* else null;
        latest.value_ptr.* = ref;
        const uses = try self.local_names.getOrPut(self.allocator, l.zig_name);
        uses.value_ptr.* = if (uses.found_existing) uses.value_ptr.* + 1 else 1;
        try top.locals.append(self.allocator, l);
        return &top.locals.items[ref.index];
    }

    /// The local an identifier leaf denotes, if it names one.
    fn localOf(self: *Emitter, leaf: Sexp) ?*Local {
        const sym = self.facts.symbolOf(leaf) orelse return null;
        return self.localBySym(sym);
    }

    fn localBySym(self: *Emitter, sym: SymbolId) ?*Local {
        const ref = self.local_by_sym.get(sym) orelse return null;
        return &self.scopes.items[ref.scope].locals.items[ref.index];
    }

    /// A Zig name for a new binding: the Rig name (escaped if needed)
    /// unless that would shadow a visible Zig name.
    fn zigNameFor(self: *Emitter, rig_name: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, rig_name, "_")) return "_";
        const base = try self.fmt("{f}", .{ident(rig_name)});
        if (!self.nameTaken(base)) return base;
        // The new name is the emitter's (`__rig_local_x_3`), so no name of
        // the program's can be it.
        return self.fresh(if (rig.isPlainName(rig_name)) try self.fmt("__rig_local_{s}", .{rig_name}) else "__rig_hidden");
    }

    /// Whether a Zig name is visible where a binding is being declared:
    /// a module-level name, the nominal type being emitted or one of its
    /// methods, or a local. Every name compared is a Zig name
    /// (`ident`), as Zig compares them.
    fn nameTaken(self: *Emitter, zig_name: []const u8) bool {
        if (self.module_names.contains(zig_name)) return true;
        if (self.nominal) |n| {
            if (std.mem.eql(u8, n.name, zig_name)) return true;
            for (n.methods) |m| if (std.mem.eql(u8, m, zig_name)) return true;
        }
        return self.local_names.contains(zig_name);
    }

    fn fresh(self: *Emitter, base: []const u8) Error![]const u8 {
        while (true) {
            self.counter += 1;
            const name = try self.fmt("{s}_{d}", .{ base, self.counter });
            if (!self.nameTaken(name)) return name;
        }
    }

    /// How a hidden storage location's name ends (`hiddenStorage`).
    const StorageSuffix = union(enum) {
        /// A fresh number: `__rig_tmp_7`.
        next,
        /// The number of the construct it belongs to: `__rig_recv_3`.
        id: u32,
        /// That number and its place there: `__rig_arg_3_1`.
        pair: [2]u32,
        /// A name no local has: `__rig_whole`, `__rig_whole_4`.
        fresh,
        /// A copy of the storage named here: `__rig_opt_5_v`.
        copy_of: []const u8,
    };

    /// The Zig name of the hidden storage of `kind` emit makes for
    /// `node`, held `by` (`facts.Storage`). Every hidden storage location
    /// is named here: the storage facts must record it, held the same
    /// way, or emit would make storage the ownership checker did not walk.
    fn hiddenStorage(self: *Emitter, node: Sexp, kind: facts.StorageKind, by: facts.StorageBy, suffix: StorageSuffix) Error![]const u8 {
        const fact = self.facts.storageOf(node, kind) orelse return self.unsupported(node, "hidden storage the storage facts do not record");
        // A statement's slot is declared before it runs; its value is
        // written where the temporary is.
        if (kind != .temp) try self.inUnit(node);
        if (fact.by != by) return self.unsupported(node, "hidden storage held other than its storage fact says");
        const base: []const u8 = switch (kind) {
            .temp => "__rig_tmp",
            .header_value => "__rig_hdr",
            .held => "__rig_held",
            .taken => "__rig_src",
            .iterator => "__rig_it",
            .element => "__rig_elem",
            .range_start => "__rig_i",
            .range_end => "__rig_end",
            .range_more => "__rig_more",
            .subject => "__rig_subject",
            .whole => "__rig_whole",
            .payload => "__rig_payload",
            .as_value => "__rig_opt",
            .lent => "__rig_lent",
            .erased_copy => "__rig_erased",
            .leaf => "__rig_leaf",
            .error_value => "__rig_err",
            .argument => "__rig_arg",
            .receiver => "__rig_recv",
            .environment, .closure_env => "__rig_env",
            .invoked => "__rig_fn",
            .new_value => "__rig_new",
            .base => "__rig_base",
            .index => "__rig_ix",
            .slot => "__rig_slot",
            .results => "__rig_res",
            // The storage of these is another's: the header's value, the
            // capture it copies, or Zig's (`zigTemporary`).
            .header_copy, .as_copy, .zig_temp => "",
        };
        return switch (suffix) {
            .next => self.fmt("{s}_{d}", .{ base, self.nextId() }),
            .id => |id| self.fmt("{s}_{d}", .{ base, id }),
            .pair => |p| self.fmt("{s}_{d}_{d}", .{ base, p[0], p[1] }),
            .fresh => self.fresh(base),
            .copy_of => |of| self.fmt("{s}_v", .{of}),
        };
    }

    /// Take the address of `node`, a value Zig holds for its statement in
    /// no slot: the storage facts must record it (`zig_temp`), so the
    /// checker knew emit reaches it there.
    fn zigTemporary(self: *Emitter, node: Sexp) Error!void {
        const fact = self.facts.storageOf(node, .zig_temp) orelse return self.unsupported(node, "an address of a value Zig holds that the storage facts do not record");
        if (fact.by != .owned) return self.unsupported(node, "a Zig temporary held other than its storage fact says");
    }

    /// A decision a pass made before emit (`facts.Question`), which emit
    /// only reads: one no pass made is an internal error.
    fn need(self: *Emitter, answer: anytype, node: Sexp) Error!@typeInfo(@TypeOf(answer)).optional.child {
        return answer orelse self.unsupported(node, "a decision no checker made: " ++ @typeName(@TypeOf(answer)));
    }

    fn nextId(self: *Emitter) u32 {
        self.counter += 1;
        return self.counter;
    }

    fn fmt(self: *Emitter, comptime f: []const u8, args: anytype) Error![]const u8 {
        return self.arena.allocator().print(f, args);
    }

    // =========================================================================
    // Resource guards
    // =========================================================================

    /// `defer ...` that drops `local` at scope exit.
    fn emitGuard(self: *Emitter, local: *const Local) Error!void {
        const kind = local.kind orelse return;
        // A flag for each field a use may move out, which its move
        // clears; set again where the field is assigned.
        for (local.part_flags) |f| {
            try self.w.print("var {s} = true;\n", .{f});
            try self.writeIndent(self.indent);
        }
        switch (local.guard) {
            .none => for (local.part_flags) |f| try self.w.print("_ = &{s};", .{f}),
            .scope => {
                try self.w.writeAll("defer ");
                try self.writeLocalDrop(local, kind);
                try self.w.writeAll(";");
            },
            .flag => {
                // The defer clears the flag itself, so the flag is a mutated
                // `var` even when nothing consumes the binding.
                try self.w.print("var {s} = true;\n", .{local.flag});
                try self.writeIndent(self.indent);
                try self.w.print("defer if ({s}) {{ {s} = false; ", .{ local.flag, local.flag });
                try self.writeLocalDrop(local, kind);
                try self.w.writeAll("; };");
            },
        }
    }

    /// Drop `local`'s value: only the fields it still holds when a use
    /// may move some out (`Local.parts`), each behind its flag.
    fn writeLocalDrop(self: *Emitter, local: *const Local, kind: ResourceKind) Error!void {
        if (local.parts.len == 0) return self.writeDrop(local.zig_name, kind);
        try self.w.print("rig.dropParts(&{s}, ", .{local.zig_name});
        try self.writeParts(local, "", local.parts.len);
        try self.w.writeAll(")");
    }

    /// Whether a field of `local` a use may move out is at or below `path`.
    fn partsBelow(_: *Emitter, local: *const Local, path: []const u8) bool {
        for (local.parts) |p| if (partUnder(p, path) != null) return true;
        return false;
    }

    /// `&.{ "a", "a.b" }, &.{ f1, f2 }`: the paths of `local`'s fields
    /// moved out at or below `under` (`""` for all of them), relative to
    /// it, and their flags.
    fn writeParts(self: *Emitter, local: *const Local, under: []const u8, _: usize) Error!void {
        try self.w.writeAll("&.{");
        var n: usize = 0;
        for (local.parts) |p| if (partUnder(p, under)) |rel| {
            try self.w.print("{s} \"", .{if (n > 0) "," else ""});
            try writeZigPath(self.w, rel);
            try self.w.writeAll("\"");
            n += 1;
        };
        try self.w.writeAll(" }, &.{");
        n = 0;
        for (local.parts, local.part_flags) |p, f| if (partUnder(p, under) != null) {
            try self.w.print("{s} {s}", .{ if (n > 0) "," else "", f });
            n += 1;
        };
        try self.w.writeAll(" }");
    }

    /// A path of Rig field names as the Zig struct names those fields
    /// (`rig.writeZigIdent`), which `rig.dropParts` compares with them: a
    /// field Zig would take for its own is renamed `debug'`.
    fn writeZigPath(w: *Writer, path: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, path, '.');
        var first = true;
        while (it.next()) |name| {
            if (!first) try w.writeAll(".");
            first = false;
            try w.writeAll(name);
            if (rig.zigRenames(name)) try w.writeAll("'");
        }
    }

    /// Path `p` relative to `under`: `""` for `under` itself, `b` for
    /// `a.b` under `a`; null when `p` is not at or below `under`.
    fn partUnder(p: []const u8, under: []const u8) ?[]const u8 {
        if (under.len == 0) return p;
        if (std.mem.eql(u8, p, under)) return "";
        if (p.len > under.len and std.mem.startsWith(u8, p, under) and p[under.len] == '.') return p[under.len + 1 ..];
        return null;
    }

    /// The local a field path names, `p` of `p.a.b`, and the path below
    /// it, `a.b`, when the local has fields a use may move out.
    fn partsOf(self: *Emitter, e: Sexp) Error!?struct { local: *Local, path: []const u8 } {
        if (!e.isKind(.member)) return null;
        var fields: std.ArrayList([]const u8) = .empty;
        var p = e;
        while (p.isKind(.member)) : (p = ir.Member.object(p)) {
            const name = ir.Member.name(p);
            if (name != .src) return null;
            try fields.append(self.arena.allocator(), self.srcText(name));
        }
        if (p != .src) return null;
        const local = self.localOf(p) orelse return null;
        if (local.parts.len == 0) return null;
        std.mem.reverse([]const u8, fields.items);
        return .{ .local = local, .path = try std.mem.join(self.arena.allocator(), ".", fields.items) };
    }

    /// How a resource binding's drop is armed: behind an alive flag when
    /// it may be consumed first.
    fn resourceGuard(self: *Emitter, sym: SymbolId) Guard {
        return if (self.facts.consumes(sym)) .flag else .scope;
    }

    /// `var _h = base`, for a `header` that holds the value it makes of
    /// which its subject is a part (`SemContext.heldBaseOf`), dropped
    /// where the block the caller opened around the construct ends.
    /// Until the caller restores the returned hoisted count, emitting
    /// the base reads `_h`.
    fn emitHeld(self: *Emitter, header: Sexp) Error!usize {
        const base = self.facts.heldBaseOf(header) orelse return self.unsupported(header, "a held header without its base");
        const mark = self.hoisted.items.len;
        const name = try self.hiddenStorage(header, .held, .owned, .next);
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = ", .{name});
        try self.emitBare(base);
        try self.w.writeAll(";\n");
        try self.poisonAtExit(name);
        if (try self.dropKind(base)) |kind| {
            try self.writeIndent(self.indent);
            try self.w.writeAll("defer ");
            try self.writeDrop(name, kind);
            try self.w.writeAll(";\n");
        } else try self.line("_ = &{s};", .{name});
        try self.hoisted.append(self.allocator, .{ .node = base, .name = name });
        return mark;
    }

    fn writeDrop(self: *Emitter, place: []const u8, kind: ResourceKind) Error!void {
        switch (kind) {
            .shared => try self.w.print("{s}.dropStrong()", .{place}),
            .weak => try self.w.print("{s}.dropWeak()", .{place}),
            .value, .optional => try self.w.print("rig.drop(&{s})", .{place}),
        }
    }

    /// The alive flag that must be cleared when `local`'s value leaves.
    fn consumeFlag(local: *const Local) ?[]const u8 {
        return if (local.guard == .flag) local.flag else null;
    }

    // =========================================================================
    // Blocks and statements
    // =========================================================================

    /// The statements of a block, or a lone statement as a list of one.
    fn stmtsOf(self: *Emitter, body: Sexp) Error![]const Sexp {
        if (body.isKind(.block)) return ir.Block.stmts(body);
        return self.arena.allocator().dupe(Sexp, &.{body});
    }

    fn openBrace(self: *Emitter) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();
    }

    fn closeBrace(self: *Emitter) Error!void {
        try self.popScope();
        self.indent -= 1;
        try self.writeIndent(self.indent);
        try self.w.writeAll("}");
    }

    /// `{ stmts }` for a statement-position block.
    fn emitBlock(self: *Emitter, body: Sexp) Error!void {
        try self.openBrace();
        try self.emitFunPrologue();
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitStmts(self: *Emitter, stmts: []const Sexp) Error!void {
        for (stmts) |stmt| {
            try self.writeIndent(self.indent);
            try self.emitStmt(stmt);
            try self.w.writeAll("\n");
        }
    }

    /// A function body whose last expression statement is its value.
    fn emitValueBody(self: *Emitter, body: Sexp) Error!void {
        try self.openBrace();
        try self.emitFunPrologue();
        const stmts = try self.stmtsOf(body);
        const last = stmts.len - 1;
        try self.emitStmts(stmts[0..last]);
        try self.writeIndent(self.indent);
        if (self.yieldsValue(stmts[last])) {
            const first = self.temp_slots.items.len;
            defer self.temp_slots.shrinkRetainingCapacity(first);
            const erased = self.erased_slots.items.len;
            defer self.erased_slots.shrinkRetainingCapacity(erased);
            try self.emitFlag(stmts[last]);
            try self.emitErasedSlots(stmts[last]);
            try self.emitTempSlots(stmts[last]);
            try self.w.writeAll("return ");
            try self.emitReturnValue(stmts[last]);
            try self.w.writeAll(";");
        } else {
            try self.emitStmt(stmts[last]);
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// A statement, with the slots of the owning temporaries it drops at
    /// its end: declared before it, each with a `defer` for an exit from
    /// inside it (a failure, a jump), and dropped right after it.
    fn emitStmt(self: *Emitter, sexp: Sexp) Error!void {
        try self.emitFlag(sexp);
        const entered = try self.enterUnit(sexp);
        defer self.leaveUnit(entered);
        const erased = self.erased_slots.items.len;
        defer self.erased_slots.shrinkRetainingCapacity(erased);
        try self.emitErasedSlots(sexp);
        const first = self.temp_slots.items.len;
        try self.emitTempSlots(sexp);
        defer self.temp_slots.shrinkRetainingCapacity(first);
        try self.emitStmtOnly(sexp);
        if (isTerminatingStmt(sexp)) return;
        // The last made is dropped first, as the `defer`s would.
        var i = self.temp_slots.items.len;
        while (i > first) {
            i -= 1;
            try self.writeTempDrop(self.temp_slots.items[i].name);
        }
    }

    fn writeTempDrop(self: *Emitter, name: []const u8) Error!void {
        try self.w.print(" if ({s}_live) {{ {s}_live = false; rig.drop(&{s}); }}", .{ name, name, name });
        if (self.poison) try self.w.print(" rig.poison(&{s});", .{name});
    }

    /// Declare a slot for each owning temporary in statement `stmt` (not
    /// in the blocks or closures it holds, whose statements are emitted
    /// on their own, or in its headers, which are their own statements:
    /// `openHeader`) that has none yet, inline before the statement.
    /// Declare a slot for each copy an API object in statement `stmt`
    /// views (`sema.stmtErasedCopies`), before the statement, so it lives
    /// to its block's end: `var __rig_erased_3: Point = undefined;`.
    fn emitErasedSlots(self: *Emitter, stmt: Sexp) Error!void {
        var nodes: std.ArrayList(Sexp) = .empty;
        try self.facts.stmtErasedCopies(self.arena.allocator(), stmt, &nodes);
        for (nodes.items) |n| {
            const key = erasedKey(n) orelse continue;
            if (self.erasedSlot(n) != null) continue;
            const e = self.facts.erasureOf(n) orelse continue;
            const name = try self.hiddenStorage(n, .erased_copy, .copy, .next);
            try self.w.print("var {s}: ", .{name});
            try self.emitTypeTy(e.from);
            try self.w.writeAll(" = undefined; ");
            try self.erased_slots.append(self.allocator, .{ .key = key, .name = name });
        }
    }

    /// Whether statement `stmt` erases a value to an API object of a copy
    /// (`sema.stmtErasedCopies`), whose slot a block declares.
    fn hasErasedCopies(self: *Emitter, stmt: Sexp) Error!bool {
        var nodes: std.ArrayList(Sexp) = .empty;
        try self.facts.stmtErasedCopies(self.arena.allocator(), stmt, &nodes);
        return nodes.items.len > 0;
    }

    fn erasedSlot(self: *Emitter, n: Sexp) ?[]const u8 {
        const key = erasedKey(n) orelse return null;
        for (self.erased_slots.items) |s| if (s.key == key) return s.name;
        return null;
    }

    fn emitTempSlots(self: *Emitter, stmt: Sexp) Error!void {
        var temps: std.ArrayList(Sexp) = .empty;
        try self.facts.stmtTemps(self.arena.allocator(), stmt, &temps);
        for (temps.items) |temp| {
            if (self.tempSlot(temp) != null) continue;
            const name = try self.hiddenStorage(temp, .temp, .owned, .next);
            try self.w.print("var {s}: ", .{name});
            try self.emitTypeTy(self.typeOf(temp) orelse return self.unsupported(temp, "an untyped temporary"));
            try self.w.print(" = undefined; var {s}_live = false; ", .{name});
            if (self.poison) try self.w.print("defer rig.poison(&{s}); ", .{name});
            try self.w.print("defer if ({s}_live) rig.drop(&{s}); ", .{ name, name });
            try self.temp_slots.append(self.allocator, .{ .node = temp.list.id, .name = name });
        }
    }

    fn tempSlot(self: *Emitter, node: Sexp) ?TempSlot {
        if (node != .list) return null;
        for (self.temp_slots.items) |t| if (t.node == node.list.id) return t;
        return null;
    }

    /// Whether statement `stmt` holds an owning temporary its end drops
    /// (`sema.firstStmtTemp`).
    fn hasTemps(self: *Emitter, stmt: Sexp) bool {
        return self.facts.firstStmtTemp(stmt) != null;
    }

    /// Start header `e` (`facts.syntax.isHeaderOf`), its own statement: when it
    /// makes temporaries, a block holds their slots, whose `defer`s drop
    /// them as the block yields the header's value, `(label: { slots
    /// break :label e; })`. The caller writes the value, then calls
    /// `closeHeader`.
    fn openHeader(self: *Emitter, e: Sexp) Error!Header {
        return self.openHeaderBy(e, .copy);
    }

    /// `openHeader` for a block that yields `by`: the header's value
    /// (`copy`), or the address of the place a construct's subject
    /// reaches (`pointer`, `emitSubjectPtr`).
    fn openHeaderBy(self: *Emitter, e: Sexp, by: facts.StorageBy) Error!Header {
        const first = self.temp_slots.items.len;
        if (!self.hasTemps(e)) return .{ .first = first };
        const label = try self.hiddenStorage(e, .header_value, by, .next);
        try self.w.print("({s}: {{ ", .{label});
        try self.emitTempSlots(e);
        try self.w.print("break :{s} ", .{label});
        return .{ .label = label, .first = first };
    }

    fn closeHeader(self: *Emitter, h: Header) Error!void {
        if (h.label.len > 0) try self.w.writeAll("; })");
        self.temp_slots.shrinkRetainingCapacity(h.first);
    }

    /// Header `e`'s value, as `emitBare` writes it.
    fn emitHeader(self: *Emitter, e: Sexp) Error!void {
        const h = try self.openHeader(e);
        try self.emitBare(e);
        try self.closeHeader(h);
    }

    /// `storage.headerPoints`: the header over construct subject `e`
    /// makes temporaries, and its block yields the address of the place
    /// `e` reaches.
    fn headerPoints(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.headerPoints(e), e);
    }

    /// The address of the place a construct's subject `e` reaches, which
    /// its header's block yields (`headerPoints`), in a block that ends
    /// the header's temporaries: `(label: { slots break :label &place; })`.
    /// What the construct binds is the place's own, through the pointer:
    /// writable when the construct `writes` it.
    fn emitSubjectPtr(self: *Emitter, e: Sexp, writes: bool) Error!void {
        const h = try self.openHeaderBy(e, .pointer);
        switch (try self.need(self.facts.handsOver(e), e)) {
            .place => {
                const saved = self.read_place;
                defer self.read_place = saved;
                self.read_place = !writes;
                const saved_subject = self.subject_path;
                defer self.subject_path = saved_subject;
                self.subject_path = e;
                try self.emitAddressOf(e);
            },
            // A lend held as a pointer is the address it lends.
            .lend => try self.emitWriteViewPtr(e),
            // A value that branches over views is the view its branch
            // yields; over places, the address of the leaf it takes.
            .branches => if (self.isPtrViewExpr(e)) try self.emitWriteViewPtr(e) else try self.emitLeafPtr(e, self.typeOf(e) orelse return self.unsupported(e, "an untyped header")),
            else => return self.unsupported(e, "a header that points at no place"),
        }
        try self.closeHeader(h);
    }

    /// Whether the header over construct subject `e`, of header `node`,
    /// is evaluated as a copy: it makes temporaries and reaches no place
    /// (`headerPoints`). The checker records the same (`copiesHeader`).
    fn copiesSubject(self: *Emitter, node: Sexp, e: Sexp) Error!bool {
        const copies = self.hasTemps(e) and !try self.headerPoints(e);
        if (copies != self.facts.copiesHeader(node)) return self.unsupported(node, "a header copy the checker did not record");
        return copies;
    }

    fn emitStmtOnly(self: *Emitter, sexp: Sexp) Error!void {
        self.stmt = sexp;
        try self.inUnit(sexp);
        if (self.facts.testCheckOf(sexp)) |report| return self.emitTestCheck(sexp, report);
        const head = sexp.kind() orelse {
            try self.w.writeAll("_ = ");
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        };
        switch (head) {
            .set => try self.emitSet(sexp),
            .destructure => try self.emitDestructure(sexp),
            .drop => try self.emitDrop(sexp),
            // An empty block: a statement wherever Zig wants one.
            .pass => try self.w.writeAll("{}"),
            // `rarely`: the branch it starts is cold (`rig.cold`).
            .rarely => try self.w.writeAll("rig.cold();"),
            .@"return" => try self.emitReturn(sexp),
            .@"break" => try self.emitBreak(sexp),
            .@"continue" => try self.emitContinue(sexp),
            .panic => {
                try self.emitPanic(sexp);
                try self.w.writeAll(";");
            },
            .@"if" => try self.emitIf(sexp),
            .@"while", .@"for" => try self.emitLoop(sexp, "", null),
            .labeled => try self.emitLabeled(sexp),
            .match => try self.emitMatch(sexp, false, null),
            .block => try self.emitBlock(sexp),
            // `raw` marks an audit boundary for sema; it lowers to a block.
            .raw_block => try self.emitBlock(ir.RawBlock.body(sexp)),
            .@"defer", .@"errdefer" => {
                try self.w.print("{s} ", .{@tagName(head)});
                const body = ir.get(sexp, .body);
                if (body.isKind(.block)) try self.emitBlock(body) else try self.emitStmt(body);
            },
            else => {
                if (try self.discardsValue(sexp)) try self.w.writeAll("_ = ");
                try self.emitExpr(sexp);
                try self.w.writeAll(";");
            },
        }
    }

    /// True when `expr` in statement position produces a value that Zig
    /// requires to be used.
    fn discardsValue(self: *Emitter, expr: Sexp) Error!bool {
        var e = expr;
        while (e.isKind(.propagate)) e = ir.Propagate.value(e);
        if (!e.isKind(.call)) return true;
        if (self.isPrintCall(e) or self.stringCall(e) != null) return false;
        // A call lowered to a labeled block is an expression Zig will not
        // take as a statement.
        if (self.facts.calleeOf(e).isKind(.lambda)) return true;
        if (try self.hoistsArgs(e)) return true;
        return !self.yieldsNothing(e);
    }

    /// An expression of type `Void` or `noreturn`.
    fn yieldsNothing(self: *Emitter, e: Sexp) bool {
        const ty = self.typeOf(e) orelse return false;
        return switch (self.facts.types.get(ty)) {
            .void, .noreturn => true,
            else => false,
        };
    }

    // -------------------------------------------------------------------------
    // Bindings and assignment
    // -------------------------------------------------------------------------

    /// `(set kind target type expr)`.
    fn emitSet(self: *Emitter, sexp: Sexp) Error!void {
        try self.inUnit(sexp);
        const kind = rig.bindingKindOf(ir.Set.op(sexp));
        const target = ir.Set.target(sexp);
        const type_node = ir.Set.type(sexp);
        const expr = ir.Set.value(sexp);

        if (kind.operator()) |op| {
            // `i += c` known not to overflow (`provenOf`): `i` read once,
            // as `+=` reads it.
            const cond = if (op == .@"+" and target == .src) self.provenIf(sexp) else null;
            if (op == .@"+" and target == .src and (self.provenOf(sexp).no_overflow or (cond != null and cond.?.tests.no_overflow))) {
                try self.emitPlace(target);
                try self.w.writeAll(if (self.provenOf(sexp).no_overflow) " = rig.addProven(" else " = rig.addIf(");
                try self.emitPlace(target);
                try self.w.writeAll(", ");
                try self.emitBare(expr);
                if (!self.provenOf(sexp).no_overflow) try self.w.print(", {s}", .{cond.?.flag});
                return self.w.writeAll(");");
            }
            return self.emitCompound(sexp, op);
        }
        if (target != .src) {
            return switch (kind) {
                .default => self.emitPlaceAssign(sexp),
                else => self.unsupported(sexp, "this binding target"),
            };
        }
        if (std.mem.eql(u8, self.srcText(target), "_")) return self.emitDiscard(expr);
        // Sema decides whether the name declares a binding or
        // reassigns one.
        const sym = self.facts.symbolOf(target) orelse return self.unsupported(target, "an unresolved binding");
        // A fill is built in the local, never on the stack first.
        const in_place = try self.need(self.facts.fillsInPlace(sexp), sexp);
        if (self.facts.symbols.items[sym].decl_pos == target.src.pos) {
            if (in_place) return self.emitFillBind(target, sym, expr);
            try self.emitBind(target, sym, type_node, expr);
        } else {
            const local = self.localBySym(sym) orelse return self.unsupported(target, "an assignment to this name");
            if (in_place) {
                try self.w.writeAll("@memset(&");
                try self.writeLocalPlace(local);
                try self.w.writeAll(", ");
                try self.emitBare(ir.ArrayFill.value(expr));
                return self.w.writeAll(");");
            }
            try self.emitRebind(local.*, expr, sexp);
        }
    }

    /// `q, r = f()`: the call's results go into `__rig_res_N` (the
    /// `results` storage fact), then each target takes its own, left to
    /// right, as the binding `x = e` it is (`(set op x _ (result_part))`,
    /// whose value is `__rig_res_N[j]`); a result no target takes (`_`)
    /// is dropped at the statement's end, the last first.
    fn emitDestructure(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Destructure.value(node);
        const targets = ir.Destructure.targets(node).items();
        const ty = self.typeOf(value) orelse return self.unsupported(value, "an untyped call");
        const parts = switch (self.facts.types.get(ty)) {
            .results => |r| r,
            else => return self.unsupported(value, "a destructure of one value"),
        };
        if (parts.len != targets.len) return self.unsupported(node, "a destructure of the wrong arity");
        const kinds = try self.need(self.facts.partDrops(node), node);
        var drops = false;
        for (targets, kinds) |t, k| if (!t.isKind(.set) and k != null) {
            drops = true;
        };
        const name = try self.hiddenStorage(node, .results, .owned, .next);
        try self.w.print("{s} {s} = ", .{ if (drops) "var" else "const", name });
        try self.emitBare(value);
        try self.w.writeAll(";");
        const saved = self.part_name;
        defer self.part_name = saved;
        var taken = false;
        for (targets, 0..) |t, j| {
            if (!t.isKind(.set)) continue;
            taken = true;
            self.part_name = try self.fmt("{s}[{d}]", .{ name, j });
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitSet(t);
        }
        var j = targets.len;
        while (j > 0) {
            j -= 1;
            if (targets[j].isKind(.set)) continue;
            const kind = kinds[j] orelse continue;
            try self.w.writeAll(" ");
            try self.writeDrop(try self.fmt("{s}[{d}]", .{ name, j }), kind);
            try self.w.writeAll(";");
        }
        // Results no target takes, which own nothing.
        if (!taken and !drops) try self.w.print(" _ = {s};", .{name});
    }

    /// `_ = expr`, and a statement `<e` of anything but a name, which
    /// drops what it takes.
    fn emitDiscard(self: *Emitter, expr: Sexp) Error!void {
        // A discarded resource is dropped at once, and so is what a
        // method gives through a type parameter, whose type each
        // instance decides.
        if (self.facts.isTypeParamCall(expr)) {
            try self.w.writeAll("rig.discard(");
            try self.emitBare(expr);
            return self.w.writeAll(");");
        }
        if (try self.dropKind(expr) != null) {
            try self.w.writeAll("rig.discard(");
            try self.emitBare(expr);
            return self.w.writeAll(");");
        }
        // A named place is discarded by address: it may be used
        // elsewhere, and Zig rejects discarding a used name. (A clone,
        // or a move the checker did not record as a take, of a value
        // that owns nothing is a copy; a take empties its place.)
        var place = expr;
        const takes = place.isKind(.move) and self.facts.takes(place);
        if (!takes and (place.isKind(.read) or place.isKind(.write) or place.isKind(.clone) or place.isKind(.move))) place = ir.get(place, .operand);
        if ((try self.hasStorage(place)) and !place.isKind(.index)) {
            try self.w.writeAll("_ = &");
            try self.emitPlace(place);
            return self.w.writeAll(";");
        }
        try self.w.writeAll("_ = ");
        try self.emitBare(expr);
        try self.w.writeAll(";");
    }

    /// A new local array a fill builds in place (`storage.fillsInPlace`):
    /// `var a: [n]T = undefined; @memset(&a, x);`. The element is
    /// evaluated before the name is visible, so a shadow reads the old
    /// binding.
    fn emitFillBind(self: *Emitter, name_node: Sexp, sym: SymbolId, fill: Sexp) Error!void {
        const ty = self.symType(sym) orelse return self.unsupported(name_node, "an untyped binding");
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            try self.emitBare(ir.ArrayFill.value(fill));
        }
        const stored = try self.declare(.{ .sym = sym, .ty = ty }, self.srcText(name_node));
        try self.w.print("var {s}: ", .{stored.zig_name});
        try self.emitTypeTy(ty);
        try self.w.print(" = undefined; @memset(&{s}, {s});", .{ stored.zig_name, value_buf.written() });
    }

    /// A new binding.
    fn emitBind(self: *Emitter, name_node: Sexp, sym: SymbolId, type_node: Sexp, expr: Sexp) Error!void {
        if (expr.isKind(.lambda)) return self.emitClosureBinding(name_node, sym, expr);

        const s = self.facts.symbols.items[sym];
        const ty = self.symType(sym);
        const binds_view = if (ty) |t| switch (self.facts.types.get(t)) {
            .read_view, .write_view => true,
            else => false,
        } else true;
        // A read view that copies (`sema.lendByValue`) is held as the
        // value it views, as every other `?T` of the type is, so a call's
        // result can rebind it.
        const copies = if (ty) |t| switch (self.facts.types.get(t)) {
            .read_view => !self.isPtrViewTy(t) and self.genericReadView(t) == null,
            else => false,
        } else false;
        const is_lend = binds_view and !copies and (expr.isKind(.read) or expr.isKind(.write)) and
            (ty == null or (self.facts.writeSliceElem(ty.?) == null and self.facts.callableFn(ty.?) == null and self.facts.objectView(ty.?) == null));
        // A write view is held as a pointer however it was obtained.
        const holds_ptr = is_lend or (ty != null and self.isPtrViewTy(ty.?));
        var local: Local = .{ .sym = sym, .ty = ty, .is_ptr = holds_ptr };
        if (!holds_ptr) local.kind = self.holdOf(sym);
        if (local.kind != null) local.guard = self.resourceGuard(sym);

        const needs_ptr_self = local.kind == .value or local.kind == .optional;
        // Assigning a write view writes through it, leaving the
        // pointer as it is.
        const rebound = s.flags.repointed or s.flags.rebound;
        // A constant initializer would make a Zig `const` compile-time
        // known, and Zig would then evaluate later arithmetic on it at
        // compile time; Rig treats it as a run-time value.
        const is_var = rebound or (!holds_ptr and (s.flags.written or needs_ptr_self or
            (!s.flags.comptime_known and (isZigComptimeIn(self, expr, 0) or self.facts.isConstInt(sym)))));

        // Evaluate the value before the new name is visible, so a shadow
        // (`new x = x + 1`) reads the old binding.
        var value_buf: Writer.Allocating = .init(self.arena.allocator());
        {
            const saved_w = self.w;
            self.w = &value_buf.writer;
            defer self.w = saved_w;
            if (is_lend) {
                try self.emitLendAddress(expr);
            } else if (holds_ptr) {
                try self.emitWriteViewPtr(expr);
            } else try self.emitBareAs(expr, ty);
        }

        const stored = try self.declare(local, self.srcText(name_node));
        try self.w.print("{s} {s}", .{ if (is_var) "var" else "const", stored.zig_name });
        if (holds_ptr) {
            // A rebindable view needs its pointer type spelled out.
            if (is_var and ty != null) {
                try self.w.writeAll(": ");
                try self.emitPointerTy(ty.?);
            }
        } else {
            if (ty != null and (type_node != .nil or self.isPlainTy(ty.?) or self.isEnumTy(ty.?))) {
                // Literal and branch values need a runtime type, and so
                // does a bare variant of an enum with payloads.
                try self.w.writeAll(": ");
                try self.emitTypeTy(ty.?);
            }
        }
        try self.w.print(" = {s};", .{value_buf.written()});

        if (stored.guard != .none) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitGuard(stored);
        } else if (is_var) {
            // Zig rejects a `var` it never sees mutated. A reassignment
            // is emitted as one; any other reason for `var` (a write
            // through the binding, which may land behind a pointer
            // field, run-time arithmetic, a `*Self` method) needs the
            // discard.
            if (!rebound) try self.w.print(" _ = &{s};", .{stored.zig_name});
        } else if (self.facts.isConstInt(sym) or self.facts.isCtLocal(sym)) {
            // A constant's uses may all be folded away, and an alias of a
            // compile-time parameter may be named only in types, which
            // name the parameter.
            try self.w.print(" _ = &{s};", .{stored.zig_name});
        }
    }

    /// Reassign an existing binding. A resource's old value is dropped
    /// after the new one has been computed (so `a = +a` works), and the
    /// guard is re-armed.
    fn emitRebind(self: *Emitter, local: Local, value: Sexp, set: Sexp) Error!void {
        const writes_through = self.facts.writesThrough(set);
        if (local.is_ptr and !writes_through) {
            // A view local is rebound to view something else.
            try self.w.print("{s} = ", .{local.zig_name});
            if (value.isKind(.read) or value.isKind(.write)) try self.emitLendAddress(value) else try self.emitWriteViewPtr(value);
            return self.w.writeAll(";");
        }
        if (local.is_ptr) {
            // Through a `!T` parameter: the caller's value is replaced.
            const pointee = if (local.ty) |t| self.facts.writtenThrough(t) else null;
            if (pointee != null and self.isPtrViewTy(pointee.?)) {
                // A `!T` whose `T` is a view: the view it reaches is
                // pointed at another place, made first where the value
                // can act (`storesAfterValue`).
                if (self.facts.storageOf(value, .new_value) != null) {
                    const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = self.nextId() });
                    try self.w.print("{{ const {s} = ", .{name});
                    try self.emitWriteViewPtr(value);
                    try self.w.writeAll("; ");
                    try self.writeLocalPlace(&local);
                    return self.w.print(" = {s}; }}", .{name});
                }
                try self.writeLocalPlace(&local);
                try self.w.writeAll(" = ");
                try self.emitWriteViewPtr(value);
                return self.w.writeAll(";");
            }
            if ((try self.need(self.facts.setOrder(set), set)).drops_old) {
                const new = try self.openNewValue(pointee, value);
                return self.w.print("; rig.drop({s}); {s}.* = {s}; }}", .{ local.zig_name, local.zig_name, new.name });
            }
        }
        const kind = local.kind orelse {
            // The value is made first when it can act, so the store goes
            // through the place as the value left it (`storesAfterValue`).
            const first = self.facts.storageOf(value, .new_value) != null;
            if (first) {
                const id = self.nextId();
                const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
                try self.w.print("{{ const {s}", .{name});
                if (local.ty) |t| {
                    try self.w.writeAll(": ");
                    try self.emitTypeTy(if (local.is_ptr) self.facts.writtenThrough(t) else t);
                }
                try self.w.writeAll(" = ");
                try self.emitBareAs(value, local.ty);
                try self.w.writeAll("; ");
                try self.writeLocalPlace(&local);
                return self.w.print(" = {s}; }}", .{name});
            }
            try self.writeLocalPlace(&local);
            try self.w.writeAll(" = ");
            try self.emitBareAs(value, local.ty);
            try self.w.writeAll(";");
            return;
        };
        const new = try self.openNewValue(local.ty, value);
        try self.w.writeAll("; ");
        if (local.guard == .flag) try self.w.print("if ({s}) ", .{local.flag});
        try self.writeLocalDrop(&local, kind);
        try self.w.print("; {s} = {s};", .{ local.zig_name, new.name });
        if (local.guard == .flag) try self.w.print(" {s} = true;", .{local.flag});
        for (local.part_flags) |f| try self.w.print(" {s} = true;", .{f});
        try self.w.writeAll(" }");
    }

    /// A new value an assignment stores, `__rig_new_N`, its `N`, and the
    /// flag that guards its drop if a later step leaves (`SetOrder.guard`).
    const NewValue = struct { id: u32, name: []const u8, flag: []const u8 = "" };

    /// `{ const __rig_new_N: T = value`: a new value, computed before the
    /// one it replaces is dropped. The type lets a context-typed value
    /// (`List()`, `.variant(...)`) resolve.
    fn openNewValue(self: *Emitter, ty: ?TypeId, value: Sexp) Error!NewValue {
        const id = self.nextId();
        const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
        try self.w.print("{{ const {s}", .{name});
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitBare(value);
        return .{ .id = id, .name = name };
    }

    /// `{ __rig_new_N: T = value;`, the value of assignment `set` made in
    /// its turn, before its target's steps. When a later step can leave
    /// (`SetOrder.guard`), the value is dropped on the way out unless the
    /// store takes it, clearing the flag: `var __rig_new_N: T = value;
    /// var __rig_live_N_new = true; defer if (__rig_live_N_new) rig.drop(&__rig_new_N);`.
    fn openSetValue(self: *Emitter, set: Sexp, ty: ?TypeId, how: AssignValue) Error!NewValue {
        const value = ir.Set.value(set);
        const order = try self.need(self.facts.setOrder(set), set);
        const id = self.nextId();
        const name = try self.hiddenStorage(value, .new_value, .owned, .{ .id = id });
        const kind: ?ResourceKind = if (order.guard) try self.dropKind(value) else null;
        if (order.guard and kind == null) return self.unsupported(value, "a guarded assignment value that owns nothing");
        try self.w.print("{{ {s} {s}", .{ if (kind == .value or kind == .optional) "var" else "const", name });
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        if (how == .view) try self.emitWriteViewPtr(value) else try self.emitBare(value);
        try self.w.writeAll("; ");
        const k = kind orelse return .{ .id = id, .name = name };
        const flag = try self.fmt("__rig_live_{d}_new", .{id});
        try self.w.print("var {s} = true; defer if ({s}) ", .{ flag, flag });
        try self.writeDrop(name, k);
        try self.w.writeAll("; ");
        return .{ .id = id, .name = name, .flag = flag };
    }

    /// The new value as the store takes it: through its flag when a
    /// later step could have left (`openSetValue`).
    fn writeNewValue(self: *Emitter, new: NewValue) Error!void {
        if (new.flag.len > 0) return self.w.print("rig.take(&{s}, {s})", .{ new.flag, new.name });
        try self.w.writeAll(new.name);
    }

    /// Assignment to a field or element. When the place may hold a
    /// resource, the old value is dropped after the new one is computed.
    /// The steps run in the order of `SetOrder` (`openAssign`).
    fn emitPlaceAssign(self: *Emitter, set: Sexp) Error!void {
        const target = ir.Set.target(set);
        const value = ir.Set.value(set);
        // A target assigned through, a call's write view, writes the
        // value the view reaches (`emitTarget`).
        const through = facts.syntax.assignedThrough(target);
        const place_ty = if (through) (if (self.typeOf(target)) |t| self.facts.writtenThrough(t) else null) else self.typeOf(target);
        if (target.isKind(.index)) if (self.typeOf(ir.Index.object(target))) |t| if (self.isCellListTy(t)) {
            const order = try self.openAssign(set, self.typeOf(target), .value);
            try self.emitCellPtr(ir.Index.object(target));
            try self.w.writeAll(".listSet(");
            try self.emitBare(ir.Index.index(target));
            try self.w.writeAll(", ");
            try self.emitBare(value);
            try self.w.writeAll(");");
            return self.closeAssign(order);
        };
        const holds_view = if (through) (if (place_ty) |t| self.isPtrViewTy(t) else false) else (target != .src and self.isPtrViewExpr(target));
        if (holds_view) {
            // A field or element holding a view, or a view a call's write
            // view reaches, is pointed at another place.
            const order = try self.openAssign(set, null, .view);
            // An element is reached as the slot it is.
            if (through) try self.emitTarget(target) else if (target.isKind(.index)) try self.emitIndex(target, true) else try self.emitWriteViewPtr(target);
            try self.w.writeAll(" = ");
            try self.emitWriteViewPtr(value);
            try self.w.writeAll(";");
            return self.closeAssign(order);
        }
        const may_own = (try self.need(self.facts.setOrder(set), set)).drops_old;
        if (!may_own) {
            const order = try self.openAssign(set, place_ty, .value);
            try self.emitTarget(target);
            try self.w.writeAll(" = ");
            try self.emitBareAs(value, place_ty);
            try self.w.writeAll(";");
            // A field moved out at or below the target is held again.
            if (try self.partsOf(target)) |at| for (at.local.parts, at.local.part_flags) |p, f| if (partUnder(p, at.path) != null) {
                try self.w.print(" {s} = true;", .{f});
            };
            return self.closeAssign(order);
        }
        const new = try self.openSetValue(set, place_ty, .value);
        const first = self.hoisted.items.len;
        if ((try self.need(self.facts.setOrder(set), set)).held) try self.hoistTarget(set, new.id);
        const slot = try self.hiddenStorage(target, .slot, .pointer, .{ .id = new.id });
        try self.w.print("const {s} = &", .{slot});
        try self.emitTarget(target);
        self.hoisted.shrinkRetainingCapacity(first);
        // A field moved out, or one holding fields moved out, drops only
        // what is still held, and holds all of the new value after.
        if (try self.partsOf(target)) |at| if (self.partsBelow(at.local, at.path)) {
            try self.w.print("; rig.dropParts({s}, ", .{slot});
            try self.writeParts(at.local, at.path, 0);
            try self.w.print("); {s}.* = ", .{slot});
            try self.writeNewValue(new);
            try self.w.writeAll(";");
            for (at.local.parts, at.local.part_flags) |p, f| if (partUnder(p, at.path) != null) {
                try self.w.print(" {s} = true;", .{f});
            };
            return self.w.writeAll(" }");
        };
        try self.w.print("; rig.drop({s}); {s}.* = ", .{ slot, slot });
        try self.writeNewValue(new);
        try self.w.writeAll("; }");
    }

    /// How `openAssign` evaluates an assignment's value: as a value, or
    /// as the view a view-holding place is pointed at.
    const AssignValue = enum { value, view };

    /// Every assignment evaluates its value first, then its target from
    /// the base of its path outward, and only then finds the place and
    /// stores (SPEC §4), which is the order the ownership checker walks
    /// it in (`storage.eachSetStep`): a call in the value that grows,
    /// replaces, or frees what the target lies in cannot leave the store
    /// pointing into freed memory, and a call in the target cannot change
    /// what the value reads. When a step can act (`SetOrder.held`), this
    /// opens a block and evaluates the value into `__rig_new_N`, the base
    /// into `__rig_base_N` (`SetOrder.base`), and each index into
    /// `__rig_ix_N_k`, each in its turn and unless it is pure; the store
    /// written next names them. Returns what `closeAssign` needs, or null
    /// when nothing can act and the order is unobservable.
    fn openAssign(self: *Emitter, set: Sexp, ty: ?TypeId, how: AssignValue) Error!?usize {
        if (!(try self.need(self.facts.setOrder(set), set)).held) return null;
        const first = self.hoisted.items.len;
        const value = ir.Set.value(set);
        var id: u32 = undefined;
        if (try self.isPureArg(value)) {
            id = self.nextId();
            try self.w.writeAll("{ ");
        } else {
            const new = try self.openSetValue(set, ty, how);
            id = new.id;
            try self.hoisted.append(self.allocator, .{ .node = value, .name = new.name, .flag = new.flag, .lifted = true });
        }
        try self.hoistTarget(set, id);
        return first;
    }

    fn closeAssign(self: *Emitter, order: ?usize) Error!void {
        const first = order orelse return;
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.writeAll(" }");
    }

    /// Evaluate the steps of assignment `set`'s target that it holds, in
    /// their turn (`storage.eachTargetStep`): its base into
    /// `__rig_base_<id>` when `SetOrder.base`, then each index that is not
    /// pure into `__rig_ix_<id>_<k>`, from the base outward.
    fn hoistTarget(self: *Emitter, set: Sexp, id: u32) Error!void {
        const Steps = struct {
            e: *Emitter,
            id: u32,
            base: bool,

            pub fn step(st: @This(), s: facts.SetStep) Error!void {
                switch (s.role) {
                    .value => {},
                    .base => if (st.base) try st.e.hoistBase(s.node, st.id),
                    .index => try st.e.hoistIndex(s.node, st.id),
                }
            }
        };
        const order = try self.need(self.facts.setOrder(set), set);
        try facts.syntax.eachTargetStep(ir.Set.target(set), Steps{ .e = self, .id = id, .base = order.base });
    }

    /// `const __rig_base_<id> = base;`: the view the target's path starts
    /// from, as the path would reach it where the place is found, the
    /// pointer a write view is or the slice.
    fn hoistBase(self: *Emitter, base: Sexp, id: u32) Error!void {
        const name = try self.hiddenStorage(base, .base, .pointer, .{ .id = id });
        try self.w.print("const {s} = ", .{name});
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = false;
        if (self.isPtrViewExpr(base)) try self.emitWriteViewPtr(base) else try self.emitBare(base);
        try self.w.writeAll("; ");
        try self.hoisted.append(self.allocator, .{ .node = base, .name = name });
    }

    fn hoistIndex(self: *Emitter, index: Sexp, id: u32) Error!void {
        if (try self.isPureArg(index)) return;
        const name = try self.hiddenStorage(index, .index, .owned, .{ .pair = .{ id, @intCast(self.hoisted.items.len) } });
        try self.w.print("const {s}", .{name});
        // An index is a number, read through a view of one.
        if (self.typeOf(index)) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(self.peelViews(t));
        }
        try self.w.writeAll(" = ");
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = false;
        try self.emitBare(index);
        try self.w.writeAll("; ");
        try self.hoisted.append(self.allocator, .{ .node = index, .name = name });
    }

    /// Whether `ty` is a vector, or a view of one.
    fn isSimd(self: *Emitter, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return self.facts.types.get(self.peelViews(t)) == .simd;
    }

    /// Whether `ty` is a mask, `Simd[Bool, n]`, or a view of one: a
    /// `rig.Mask(n)`, whose operators are the runtime's (`rig.maskOr`).
    fn isMask(self: *Emitter, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return switch (self.facts.types.get(self.peelViews(t))) {
            .simd => |v| v.elem == self.facts.types.bool_id,
            else => false,
        };
    }

    /// The runtime function of a mask operator, or null for one that no mask takes.
    fn maskOperator(op: Tag) ?[]const u8 {
        return switch (op) {
            .@"&" => "rig.maskAnd(",
            .@"|" => "rig.maskOr(",
            .@"^" => "rig.maskXor(",
            .@"==" => "rig.maskEq(",
            .@"!=" => "rig.maskNe(",
            else => null,
        };
    }

    /// The runtime function that shifts a vector's lanes by one amount
    /// (`<<`, `<<%`, or `>>`).
    fn vecShift(op: Tag) []const u8 {
        return switch (op) {
            .@"<<" => "rig.vecShl",
            .@"<<%" => "rig.vecShlWrap",
            else => "rig.vecShr",
        };
    }

    /// `x op= e` on a name or place, with the place evaluated once, after
    /// `e` (`openAssign`). The operators that lower to a builtin
    /// (`@divTrunc` for integer `/`, `rig.rem`, `@shlExact`) assign the
    /// builtin's result, as do the checked operators on integer vector lanes
    /// (`laneHelper`); the others use Zig's own compound assignment.
    fn emitCompound(self: *Emitter, set: Sexp, op: Tag) Error!void {
        try self.inUnit(set);
        const target = ir.Set.target(set);
        const value = ir.Set.value(set);
        const shift = op == .@"<<" or op == .@"<<%" or op == .@">>";
        // A vector's lanes shift (`vecShift`) and saturate through the
        // runtime, which takes the amount as it is.
        const vector = self.isSimd(self.typeOf(target));
        const lanes = shift and vector;
        const mask_op: ?[]const u8 = if (self.isMask(self.typeOf(target))) switch (op) {
            .@"&" => "rig.maskAnd",
            .@"|" => "rig.maskOr",
            .@"^" => "rig.maskXor",
            else => null,
        } else null;
        const builtin: ?[]const u8 = if (mask_op) |m| m else if (lanes) vecShift(op) else if (vector and op == .@"+|") "rig.vecAddSat" else if (vector and op == .@"-|") "rig.vecSubSat" else switch (op) {
            .@"/", .@"%" => self.divBuiltin(op, target, value),
            .@"<<" => "@shlExact",
            .@"+", .@"-", .@"*" => self.laneHelper(set, op),
            else => null,
        };
        // The value of a shift is its amount, of any integer type.
        const value_ty = self.typeOf(if (shift) value else target);
        const order = try self.openAssign(set, if (value_ty) |t| self.peelViews(t) else null, .value);
        // The value is an operand of the operator, so a constant in it is
        // a run-time value, as in `x op e` (`rt_names`): Zig would check a
        // shift amount it knows when it compiles.
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        self.rt_names = true;
        if (builtin) |b| {
            var slot: []const u8 = "";
            if (target == .src) {
                try self.emitTarget(target);
                try self.w.print(" = {s}(", .{b});
                try self.emitTarget(target);
            } else {
                slot = try self.hiddenStorage(target, .slot, .pointer, .next);
                try self.w.print("{{ const {s} = &", .{slot});
                try self.emitTarget(target);
                try self.w.print("; {s}.* = {s}({s}.*", .{ slot, b, slot });
            }
            const cast = shift and !lanes;
            try self.w.writeAll(", ");
            const through = if (cast) try self.openUnsignedCast(value, self.typeOf(value), null) else false;
            try self.emitBare(value);
            if (cast) try self.closeUnsignedCast(through);
            try self.w.writeAll(if (target == .src) ");" else "); }");
            return self.closeAssign(order);
        }
        try self.emitTarget(target);
        try self.w.print(" {s}= ", .{if (op == .@"<<%") "<<" else @tagName(op)});
        const through = if (shift) try self.openUnsignedCast(value, self.typeOf(value), null) else false;
        try self.emitBare(value);
        if (shift) try self.closeUnsignedCast(through);
        try self.w.writeAll(";");
        return self.closeAssign(order);
    }

    /// What an assignment's target writes: a binding, field, or element
    /// (`emitPlace`), or, for a target assigned through
    /// (`assignedThrough`), the value the call's write view reaches: the
    /// pointer the base was held in (`hoistBase`), or the call, read
    /// through.
    fn emitTarget(self: *Emitter, target: Sexp) Error!void {
        if (!facts.syntax.assignedThrough(target)) return self.emitPlace(target);
        if (self.hoistedOf(target)) |h| return self.w.print("{s}.*", .{h.name});
        try self.w.writeAll("(");
        try self.emitWriteViewPtr(target);
        try self.w.writeAll(").*");
    }

    /// An assignable place: a binding, field, or element.
    fn emitPlace(self: *Emitter, target: Sexp) Error!void {
        if (target == .src) if (self.localOf(target)) |local| {
            if (self.subjectView(target, local)) |inner| return self.writeSubjectView(inner, local.zig_name);
            return self.writeLocalPlace(local);
        };
        if (target.isKind(.index)) {
            // An element holding a write view denotes the viewed
            // value, as a field holding one does (`emitValue`).
            if (self.onSubjectPath(target)) if (self.genericReadViewOf(target)) |inner| {
                try self.writeViewedPtrOpen(inner);
                try self.emitIndex(target, true);
                return self.w.writeAll(").*");
            };
            try self.emitIndex(target, true);
            if (self.isPtrViewExpr(target)) try self.w.writeAll(".*");
            return;
        }
        // A field of an element (`v[i].x = ...`) is reached through the
        // element's slot.
        const saved = self.place_chain;
        defer self.place_chain = saved;
        self.place_chain = true;
        try self.emitExpr(target);
    }

    /// The `T` of the generic read view `local` holds when `name` names it
    /// on the path of the `match` subject being emitted (`onSubjectPath`).
    fn subjectView(self: *Emitter, name: Sexp, local: *const Local) ?TypeId {
        if (!local.is_ptr or !self.onSubjectPath(name)) return null;
        return self.genericReadView(local.ty orelse return null);
    }

    fn writeSubjectView(self: *Emitter, inner: TypeId, zig_name: []const u8) Error!void {
        try self.writeViewedPtrOpen(inner);
        try self.w.print("{s}).*", .{zig_name});
    }

    fn writeLocalPlace(self: *Emitter, local: *const Local) Error!void {
        if (local.is_ptr) if (self.genericReadView(local.ty orelse return self.w.writeAll(local.zig_name))) |inner| {
            try self.writeViewedOpen(inner);
            try self.w.writeAll(local.zig_name);
            return self.w.writeAll(")");
        };
        try self.w.writeAll(local.zig_name);
        if (local.is_ptr) try self.w.writeAll(".*");
    }

    /// `<x` as a statement: drop now. `<e` of anything but a name drops
    /// what it takes, as `_ = <e` does.
    fn emitDrop(self: *Emitter, sexp: Sexp) Error!void {
        const target = ir.Drop.target(sexp);
        // `<p.f` of a field a use may move out: dropped now, its flag
        // cleared.
        if (try self.partsOf(target)) |at| for (at.local.parts, at.local.part_flags) |p, f| {
            if (!std.mem.eql(u8, p, at.path)) continue;
            try self.w.print("{s} = false; rig.drop(&", .{f});
            try self.emitPlace(target);
            return self.w.writeAll(");");
        };
        if (target != .src) return self.emitDiscard(target);
        const local = self.localOf(target) orelse return self.unsupported(sexp, "this drop");
        if (local.kind) |kind| {
            if (local.guard == .flag) try self.w.print("{s} = false; ", .{local.flag});
            try self.writeDrop(local.zig_name, kind);
            try self.w.writeAll(";");
            return;
        }
        // Ending a view or dropping plain data has no runtime effect;
        // the discard is the binding's use in Zig.
        try self.w.print("_ = &{s};", .{local.zig_name});
    }

    // -------------------------------------------------------------------------
    // Control flow
    // -------------------------------------------------------------------------

    /// The target being emitted that jump `node` goes to (`JumpDest`).
    fn jumpTarget(self: *Emitter, node: Sexp) Error!struct { dest: facts.JumpDest, target: *JumpTarget } {
        const dest = try self.need(self.facts.jumpDest(node), node);
        var i = self.targets.items.len;
        while (i > 0) {
            i -= 1;
            const t = &self.targets.items[i];
            if (sameNode(t.node, dest.target)) return .{ .dest = dest, .target = t };
        }
        return self.unsupported(node, "a jump to a construct that is not being emitted");
    }

    /// A fresh Zig label `__rig_<kind>_N`.
    fn newLabel(self: *Emitter, kind: []const u8) Error!*ZigLabel {
        const l = try self.arena.allocator().create(ZigLabel);
        l.* = .{ .name = try self.fmt("__rig_{s}_{d}", .{ kind, self.nextId() }) };
        return l;
    }

    /// The Zig label of a construct the program labels `$name:`: the name
    /// itself, unless a construct around it has it too (Zig rejects a
    /// label inside another of the same name).
    fn rigLabel(self: *Emitter, name: []const u8, kind: []const u8) Error!*ZigLabel {
        for (self.targets.items) |t| if (std.mem.eql(u8, t.rig_label, name)) return self.newLabel(kind);
        const l = try self.arena.allocator().create(ZigLabel);
        l.* = .{ .name = try self.fmt("{f}", .{ident(name)}) };
        return l;
    }

    /// The name of label `l`, which a jump is being written to.
    fn jumpTo(l: *ZigLabel) []const u8 {
        l.used = true;
        return l.name;
    }

    /// Write what follows into a buffer until `closeLabeled`, which puts
    /// `label: ` before it when a jump was written to the label.
    fn openLabeled(self: *Emitter, label: *ZigLabel) Error!Labeled {
        const buf = try self.arena.allocator().create(Writer.Allocating);
        buf.* = .init(self.arena.allocator());
        const l: Labeled = .{ .label = label, .saved = self.w, .buf = buf };
        self.w = &buf.writer;
        return l;
    }

    fn closeLabeled(self: *Emitter, l: Labeled) Error!void {
        self.w = l.saved;
        if (l.label.used) try self.w.print("{s}: ", .{l.label.name});
        try self.w.writeAll(l.buf.written());
    }

    /// `(return value?)`.
    fn emitReturn(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Return.value(node);
        if (value == .nil) return self.w.writeAll("return;");
        if (value.isKind(.results)) return self.emitReturnResults(value);
        try self.w.writeAll("return ");
        try self.emitReturnValue(value);
        try self.w.writeAll(";");
    }

    /// A value leaving the function. Resource bindings reached in tail
    /// position (directly, or through `if`/`match` branches) are moved
    /// out, so their scope-exit drop is disarmed.
    fn emitReturnValue(self: *Emitter, value: Sexp) Error!void {
        return self.emitResultValue(value, self.fun.return_ty);
    }

    /// `return a, b`: `return .{ a, b }`, each part a result of its type
    /// in its position, as `return x` gives `x` (`emitResultValue`).
    fn emitReturnResults(self: *Emitter, value: Sexp) Error!void {
        const ret = self.fun.return_ty orelse return self.unsupported(value, "several results from a function that gives one");
        const tys = self.facts.resultsOf(ret) orelse return self.unsupported(value, "several results from a function that gives one");
        const parts = ir.Results.values(value);
        if (self.facts.hoistsResults(value)) return self.emitHoistedResults(value, parts, tys);
        try self.w.writeAll("return .{ ");
        for (parts, tys, 0..) |p, ty, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitResultValue(p, ty);
        }
        try self.w.writeAll(" };");
    }

    /// `return a, b` whose later part can leave after an earlier one that
    /// owns (`storage.hoistsResults`): each part is made into
    /// `__rig_arg_N_i` in its turn, an owned one dropped on the way out
    /// unless the return takes it.
    fn emitHoistedResults(self: *Emitter, value: Sexp, parts: []const Sexp, tys: []const TypeId) Error!void {
        const id = self.nextId();
        const names = try self.arena.allocator().alloc([]const u8, parts.len);
        const flags = try self.arena.allocator().alloc(?[]const u8, parts.len);
        const kinds = try self.need(self.facts.partDrops(value), value);
        if (kinds.len != parts.len) return self.unsupported(value, "results of another arity than the function's");
        try self.openBrace();
        for (parts, tys, kinds, names, flags, 0..) |p, ty, kind, *name, *flag, i| {
            name.* = try self.hiddenStorage(value, .argument, .owned, .{ .pair = .{ id, @intCast(i) } });
            try self.writeIndent(self.indent);
            try self.w.print("{s} {s}: ", .{ if (kind != null) "var" else "const", name.* });
            try self.emitTypeTy(ty);
            try self.w.writeAll(" = ");
            try self.emitResultValue(p, ty);
            try self.w.writeAll(";");
            flag.* = null;
            if (kind) |k| {
                const f = try self.fmt("__rig_live_{d}_{d}", .{ id, i });
                flag.* = f;
                try self.w.print(" var {s} = true; defer if ({s}) ", .{ f, f });
                try self.writeDrop(name.*, k);
                try self.w.writeAll(";");
            }
            try self.w.writeAll("\n");
        }
        try self.writeIndent(self.indent);
        try self.w.writeAll("return .{ ");
        for (names, flags, 0..) |name, flag, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (flag) |f| try self.w.print("rig.take(&{s}, {s})", .{ f, name }) else try self.w.writeAll(name);
        }
        try self.w.writeAll(" };\n");
        try self.closeBrace();
    }

    /// `value` leaving the function as a result of type `result`.
    fn emitResultValue(self: *Emitter, value: Sexp, result: ?TypeId) Error!void {
        // A result that is a view held as a pointer, or an optional or a
        // fallible one, returns the pointer; an error value is itself.
        if (result) |r| if (self.isPtrViewTy(self.unwrapOptionals(self.unwrapFallible(r)))) {
            const error_value = if (self.typeOf(value)) |t| self.facts.isErrorValue(t) else false;
            if (!error_value) return self.emitWriteViewPtr(value);
        };
        self.bare = true;
        try self.emitValue(value, true);
    }

    /// `(break value-or-_ label?)`: leaves the loop's result block, or
    /// the loop; a value leaves the block of the loop it gives a value to.
    fn emitBreak(self: *Emitter, node: Sexp) Error!void {
        const value = ir.Break.value(node);
        const jump = try self.jumpTarget(node);
        if (jump.dest.to != .exit) return self.unsupported(node, "a `break` that does not leave its target");
        if (self.unit_trace) |tr| try tr.append(self.allocator, .{ .jump = .{ .node = node.list.id, .to = .exit } });
        const t = jump.target;
        if (value == .nil) return self.w.print("break :{s};", .{jumpTo(t.brk)});
        const ty = t.value_ty orelse return self.unsupported(node, "a `break` value outside a loop used as a value");
        try self.w.print("break :{s} ", .{jumpTo(t.brk)});
        self.bare = true;
        try self.emitValueAs(value, ty);
        try self.w.writeAll(";");
    }

    /// `(continue label?)`: the Zig jump from the part of the loop being
    /// emitted (`JumpTarget.part`) that goes where the checkers sent it
    /// (`JumpDest.to`): from the condition, `continue :loop`, which runs
    /// a step that is the continue expression; from the body,
    /// `break :body`, which goes on to the step or the head; from the
    /// step, `break :step`, which ends it.
    fn emitContinue(self: *Emitter, node: Sexp) Error!void {
        const jump = try self.jumpTarget(node);
        const t = jump.target;
        const loop = t.loop orelse return self.unsupported(node, "a `continue` to a block");
        const has_step = t.step_point != null;
        const step_continues = if (t.step_point) |sp| sp == .continue_expr else false;
        const zig: struct { to: facts.JumpDest.To, word: []const u8, label: ?*ZigLabel } = switch (t.part) {
            .cond => .{ .to = if (step_continues) .step else .head, .word = "continue", .label = loop },
            .body => .{ .to = if (has_step) .step else .head, .word = "break", .label = t.body },
            .step => .{ .to = .head, .word = "break", .label = t.step },
        };
        if (zig.to != jump.dest.to) return self.unsupported(node, "a `continue` the checkers sent elsewhere");
        if (self.unit_trace) |tr| try tr.append(self.allocator, .{ .jump = .{ .node = node.list.id, .to = zig.to } });
        const label = zig.label orelse return self.unsupported(node, "a `continue` from a part with no block");
        try self.w.print("{s} :{s};", .{ zig.word, jumpTo(label) });
    }

    /// Statement `if`: `(if cond then else?)`.
    fn emitIf(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        if (try self.hasAsMatch(cond)) return self.emitIfChain(sexp);
        if (rig.isConditionJoin(cond)) return self.emitIfJoined(sexp);
        // A value the condition holds (`Header.held`) lives in a block
        // around the `if`.
        if (cond.isKind(.as) and self.facts.headerOf(cond) == .held) {
            try self.openBrace();
            // The held value is the `as` part's code, which the `if` takes
            // up again for its test.
            const entered = try self.enterUnit(cond);
            const mark = try self.emitHeld(cond);
            if (entered) _ = try self.pauseUnit(cond);
            defer self.hoisted.shrinkRetainingCapacity(mark);
            try self.writeIndent(self.indent);
            try self.emitIfAs(sexp);
            try self.w.writeAll("\n");
            return self.closeBrace();
        }
        return self.emitIfAs(sexp);
    }

    /// `emitIf` once a held value is in place.
    fn emitIfAs(self: *Emitter, sexp: Sexp) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        try self.w.writeAll("if ");
        if (rig.isAsPart(cond)) {
            try self.pushScope();
            try self.emitBodyWith(ir.If.then(sexp), try self.emitCond(cond));
            try self.popScope();
        } else {
            _ = try self.emitCond(cond);
            try self.emitBranchStmt(ir.If.then(sexp));
        }
        if (else_ != .nil) {
            try self.w.writeAll(" else ");
            if (else_.isKind(.@"if")) try self.emitIf(else_) else try self.emitBranchStmt(else_);
        }
    }

    /// The parts of a binding condition (`rig.bindsInCondition`), in order.
    fn conditionParts(self: *Emitter, cond: Sexp) Error![]const Sexp {
        const Parts = struct {
            list: std.ArrayList(Sexp) = .empty,
            a: std.mem.Allocator,
            pub fn part(v: *@This(), p: Sexp) Error!void {
                try v.list.append(v.a, p);
            }
        };
        var parts: Parts = .{ .a = self.arena.allocator() };
        try facts.syntax.eachGuardPart(cond, &parts);
        return parts.list.items;
    }

    /// One nested `if` per part of a binding condition, each opening its
    /// block and binding its name (`emitCond`); `fail`, when given, is the
    /// `else` of each. The caller closes them with `closeParts`.
    fn openParts(self: *Emitter, parts: []const Sexp) Error!void {
        for (parts, 0..) |p, i| {
            if (i > 0) try self.writeIndent(self.indent);
            try self.w.writeAll("if ");
            const prelude = try self.emitCond(p);
            try self.openBrace();
            try self.emitPrelude(prelude);
        }
    }

    fn closeParts(self: *Emitter, n: usize, fail: ?[]const u8) Error!void {
        for (0..n) |i| {
            try self.closeBrace();
            if (fail) |f| try self.w.print(" else {s}", .{f});
            if (i + 1 < n) try self.w.writeAll("\n");
        }
    }

    /// Statement `if a as x and ...`: nested `if`s, one per part, sharing
    /// one `else`, which a flag cleared on the way into the body selects.
    ///
    ///     {
    ///         var __rig_else_N = true;
    ///         if (a) |x| { if (x > 0) { __rig_else_N = false; ... } }
    ///         if (__rig_else_N) { ... }
    ///     }
    fn emitIfJoined(self: *Emitter, sexp: Sexp) Error!void {
        const parts = try self.conditionParts(ir.If.cond(sexp));
        const else_ = ir.If.@"else"(sexp);
        try self.pushScope();
        var flag: ?[]const u8 = null;
        if (else_ != .nil) {
            flag = try self.fmt("__rig_else_{d}", .{self.nextId()});
            try self.openBrace();
            try self.line("var {s} = true;", .{flag.?});
            try self.writeIndent(self.indent);
        }
        try self.openParts(parts);
        if (flag) |f| try self.line("{s} = false;", .{f});
        try self.emitStmts(try self.stmtsOf(ir.If.then(sexp)));
        try self.closeParts(parts.len, null);
        try self.popScope();
        if (flag) |f| {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("if ({s}) ", .{f});
            if (else_.isKind(.@"if")) {
                try self.openBrace();
                try self.writeIndent(self.indent);
                try self.emitIf(else_);
                try self.w.writeAll("\n");
                try self.closeBrace();
            } else try self.emitBranchStmt(else_);
            try self.w.writeAll("\n");
            try self.closeBrace();
        }
    }

    /// Whether a condition has a part `s as .circle(r)` (`as_match`),
    /// which `emitChain` writes.
    fn hasAsMatch(self: *Emitter, cond: Sexp) Error!bool {
        if (!rig.bindsInCondition(cond)) return false;
        for (try self.conditionParts(cond)) |p| if (p.isKind(.as_match)) return true;
        return false;
    }

    /// The parts of a condition from `parts[i]` on, each around the rest,
    /// and `end` inside the last: a Bool part is an `if`, an `as` part an
    /// `if` that binds (`emitCond`), and `s as .circle(r)` the `match` it
    /// is (`rig.asMatchOf`), whose first arm goes on and whose other arm
    /// (`_`, dropping what `<s` took) does not. A part that fails runs
    /// `miss`, when given (`break` in a loop), and otherwise falls
    /// through, past the parts.
    /// `end.run(emitter)` writes what the innermost part goes on to.
    fn emitChain(self: *Emitter, parts: []const Sexp, i: usize, end: anytype, miss: ?[]const u8) Error!void {
        if (i == parts.len) return end.run(self);
        const p = parts[i];
        try self.writeIndent(self.indent);
        if (p.isKind(.as_match)) {
            const arms: ChainArms(@TypeOf(end)) = .{ .parts = parts, .i = i, .end = end, .miss = miss };
            // The part is the selection unit of its `match`, which ends
            // once the first arm has bound the pattern's fields: the rest
            // of the condition and the body are units after it
            // (`rig.eachUnit`).
            const m = rig.asMatchOf(p);
            _ = try self.enterUnit(m);
            try self.emitMatch(m, false, &arms);
            try self.endUnit(m);
            return self.w.writeAll("\n");
        }
        try self.w.writeAll("if ");
        const prelude = try self.emitCond(p);
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitChain(parts, i + 1, end, miss);
        try self.closeBrace();
        if (miss) |m| try self.w.print(" else {s};", .{m});
        try self.w.writeAll("\n");
    }

    /// The arms of the `match` a part `s as .circle(r)` is, in a chain
    /// (`emitChain`): the first goes on with the parts after it, the other
    /// runs the chain's `miss`, or falls through.
    fn ChainArms(comptime End: type) type {
        return struct {
            parts: []const Sexp,
            i: usize,
            end: End,
            miss: ?[]const u8,

            fn arm(a: *const @This(), e: *Emitter, index: usize, prelude: Prelude) Error!void {
                try e.openBrace();
                try e.emitPrelude(prelude);
                if (index == 0) {
                    try e.endUnit(rig.asMatchOf(a.parts[a.i]));
                    try e.emitChain(a.parts, a.i + 1, a.end, a.miss);
                } else if (a.miss) |m| try e.line("{s};", .{m});
                try e.closeBrace();
            }
        };
    }

    /// Statement `if` whose condition has a part `s as .circle(r)`: the
    /// parts nested (`emitChain`), sharing one `else`, which a flag
    /// cleared on the way into the body selects, as `emitIfJoined` does.
    fn emitIfChain(self: *Emitter, sexp: Sexp) Error!void {
        const else_ = ir.If.@"else"(sexp);
        try self.openBrace();
        var flag: ?[]const u8 = null;
        if (else_ != .nil) {
            flag = try self.fmt("__rig_else_{d}", .{self.nextId()});
            try self.line("var {s} = true;", .{flag.?});
        }
        try self.pushScope();
        const End = struct {
            sexp: Sexp,
            flag: ?[]const u8,
            fn run(c: *const @This(), e: *Emitter) Error!void {
                if (c.flag) |f| try e.line("{s} = false;", .{f});
                try e.emitStmts(try e.stmtsOf(ir.If.then(c.sexp)));
            }
        };
        const end: End = .{ .sexp = sexp, .flag = flag };
        try self.emitChain(try self.conditionParts(ir.If.cond(sexp)), 0, &end, null);
        try self.popScope();
        if (flag) |f| {
            try self.writeIndent(self.indent);
            try self.w.print("if ({s}) ", .{f});
            if (else_.isKind(.@"if")) {
                try self.openBrace();
                try self.writeIndent(self.indent);
                try self.emitIf(else_);
                try self.w.writeAll("\n");
                try self.closeBrace();
            } else try self.emitBranchStmt(else_);
            try self.w.writeAll("\n");
        }
        try self.closeBrace();
    }

    /// `(cond) ` for `if`/`while`, or the head of `if expr as name`,
    /// whose prelude binds the name (`emitOptionalHead`).
    fn emitCond(self: *Emitter, cond: Sexp) Error!Prelude {
        var entered = try self.enterUnit(cond);
        defer self.leaveUnit(entered);
        if (cond.isKind(.as)) return self.emitOptionalHead(cond);
        if (cond.isKind(.as_results)) {
            const prelude = try self.emitResultsHead(cond);
            // The names take their results in the part's code, taken up
            // again at the body's start (`bindResults`).
            if (entered and try self.pauseUnit(cond)) entered = false;
            return prelude;
        }
        try self.w.writeAll("(");
        try self.emitHeader(cond);
        try self.w.writeAll(") ");
        return .{};
    }

    /// A statement-position body that starts with `prelude`.
    fn emitBodyWith(self: *Emitter, body: Sexp, prelude: Prelude) Error!void {
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
    }

    fn emitBranchStmt(self: *Emitter, branch: Sexp) Error!void {
        if (branch.isKind(.block)) return self.emitBlock(branch);
        try self.w.writeAll("{ ");
        try self.emitStmt(branch);
        try self.w.writeAll(" }");
    }

    /// `(labeled name stmt)`: a labeled loop, or a labeled `match`, `raw`
    /// block, or block, which `break $name` leaves as it leaves a Zig
    /// labeled block.
    fn emitLabeled(self: *Emitter, sexp: Sexp) Error!void {
        const stmt = ir.Labeled.stmt(sexp);
        const name = self.srcText(ir.Labeled.label(sexp));
        if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) return self.emitLoop(stmt, name, null);
        const label = try self.rigLabel(name, "label");
        try self.targets.append(self.allocator, .{ .node = stmt, .rig_label = name, .brk = label, .part = .body });
        defer _ = self.targets.pop();
        const l = try self.openLabeled(label);
        try self.openBrace();
        try self.emitStmts(&.{stmt});
        try self.closeBrace();
        try self.closeLabeled(l);
    }

    /// A loop being emitted (`emitLoop`).
    const Loop = struct {
        /// The block around the loop, which holds what its header holds
        /// and its `else`, and gives a loop used as a value its value.
        res: *ZigLabel,
        /// That block, once opened.
        outer: ?Labeled = null,
        /// The Zig loop.
        loop: *ZigLabel,
        /// The block of the body, which a `continue` leaves.
        body: *ZigLabel,
        target: JumpTarget,
        /// Its index in `targets`, once entered.
        index: usize = 0,
        /// A `for` whose source's unit is being written (`enterUnit`),
        /// until the loop is entered.
        source_unit: bool = false,
        /// The count of turns of the outermost loop it is in, or its own
        /// (`Emitter.yield_checks`), which it counts down as each turn
        /// ends and the next begins: in a Zig `while`, in its continue
        /// expression, so a turn that leaves the loop counts nothing;
        /// in Zig's own `for`, which has none, as each turn's body
        /// starts (`top_turn`).
        turns: ?[]const u8 = null,
        top_turn: bool = false,
    };

    /// `while` and every form of `for` (docs/internals/INTERNALS.md, "Loops"):
    ///
    ///     __rig_loop_N: {                  // when there is an `else`, a value, or a held header
    ///         <the values the header holds>
    ///         L: while (true) : (step) {   // or Zig's own `for`, `while (it.next())`
    ///             <one `if` per condition part, each `else break`>
    ///             __rig_body_N: { body }   // `continue` is `break :__rig_body_N`
    ///             <a step that reads a binding of the condition>
    ///         }
    ///         <else>
    ///     }
    ///
    /// A `break` leaves the outer block when there is one, so it skips the
    /// `else`, and otherwise the loop. A label is written only where a
    /// jump goes to it (`openLabeled`).
    fn emitLoop(self: *Emitter, loop: Sexp, rig_label: []const u8, value: ?TypeId) Error!void {
        const else_ = ir.get(loop, .@"else");
        var lp: Loop = .{
            .res = try self.newLabel("loop"),
            .loop = if (rig_label.len > 0) try self.rigLabel(rig_label, "label") else try self.newLabel(if (loop.isKind(.@"while")) "while" else "for"),
            .body = try self.newLabel("body"),
            .target = undefined,
        };
        const has_res = else_ != .nil or value != null;
        lp.target = .{ .node = loop, .rig_label = rig_label, .brk = if (has_res) lp.res else lp.loop, .loop = lp.loop, .body = lp.body, .value_ty = value };
        if (has_res) try self.openLoopBlock(&lp);
        // Every loop counts its turns: an outermost loop keeps the count,
        // in the block around it, and the loops in it count it down too,
        // so an inner loop that runs long between the outer loop's turns
        // still reaches a yield check.
        const outer_turns = self.fun.turns;
        defer self.fun.turns = outer_turns;
        if (self.yield_checks) {
            if (self.fun.loops == 0 or outer_turns == null) {
                try self.openLoopBlock(&lp);
                lp.turns = try self.fmt("__rig_turns_{d}", .{self.nextId()});
                try self.line("var {s}: u32 = rig.tick_turns;", .{lp.turns.?});
                self.fun.turns = lp.turns;
            } else lp.turns = outer_turns;
        }
        self.fun.loops += 1;
        defer self.fun.loops -= 1;
        const depth = self.targets.items.len;
        // A `for` source's code is its unit's until the loop starts.
        if (loop.isKind(.@"for")) lp.source_unit = try self.enterUnit(ir.For.source(loop));
        if (loop.isKind(.@"while")) try self.emitWhile(loop, &lp) else try self.emitFor(loop, &lp);
        self.leaveUnit(lp.source_unit);
        // The loop has ended: a jump in its `else` targets the loop around it.
        std.debug.assert(self.targets.items.len == depth + 1);
        _ = self.targets.pop();
        if (else_ != .nil) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            if (value) |ty| {
                try self.w.print("break :{s} ", .{jumpTo(lp.res)});
                try self.emitValueBlock(else_, .{}, ty);
                try self.w.writeAll(";");
            } else try self.emitBranchStmt(else_);
        }
        if (lp.outer) |o| {
            try self.w.writeAll("\n");
            try self.closeBrace();
            try self.closeLabeled(o);
        }
    }

    /// Open the block around loop `lp`, if it is not open yet.
    fn openLoopBlock(self: *Emitter, lp: *Loop) Error!void {
        if (lp.outer != null) return;
        lp.outer = try self.openLabeled(lp.res);
        try self.openBrace();
    }

    /// Where the Zig loop starts: on a line of its own in the block
    /// around it.
    fn startLoopLine(self: *Emitter, lp: *Loop) Error!void {
        if (lp.outer != null) try self.writeIndent(self.indent);
    }

    /// Make loop `lp` the target of the jumps that go to it, emitting its
    /// condition until its body opens.
    fn enterLoop(self: *Emitter, lp: *Loop) Error!void {
        self.leaveUnit(lp.source_unit);
        lp.source_unit = false;
        lp.target.part = .cond;
        lp.index = self.targets.items.len;
        try self.targets.append(self.allocator, lp.target);
    }

    /// Open the body's block, which a `continue` leaves.
    fn openLoopBody(self: *Emitter, lp: *Loop) Error!Labeled {
        self.targets.items[lp.index].part = .body;
        const l = try self.openLabeled(lp.body);
        try self.openBrace();
        if (lp.turns) |n| if (lp.top_turn) try self.line("rig.turn(&{s});", .{n});
        return l;
    }

    /// The continue expression of loop `lp`'s Zig `while`: the loop's
    /// turn counted, then `step`, Zig statements (none, or one `x += 1`
    /// with no `;`, or several, each with its own).
    fn writeStep(self: *Emitter, lp: *const Loop, step: []const u8) Error!void {
        const one = std.mem.indexOfScalar(u8, step, ';') == null;
        if (lp.turns) |n| {
            if (step.len == 0) return self.w.print(": (rig.turn(&{s})) ", .{n});
            return self.w.print(": ({{ rig.turn(&{s}); {s}{s} }}) ", .{ n, step, if (one) ";" else "" });
        }
        if (step.len == 0) return;
        if (one) return self.w.print(": ({s}) ", .{step});
        try self.w.print(": ({{ {s} }}) ", .{step});
    }

    /// The body's statements and the end of its block.
    fn closeLoopBody(self: *Emitter, lp: *Loop, l: Labeled, body: Sexp) Error!void {
        try self.emitStmts(try self.stmtsOf(body));
        try self.closeBrace();
        try self.closeLabeled(l);
        self.targets.items[lp.index].part = .cond;
    }

    /// `(while cond step body else?)` (`emitLoop`): a `while (true)` with
    /// one `if` per part of the condition inside, each leaving the loop
    /// when it fails, then the body's block. A step that runs after the
    /// body (`StepPoint.after_body`) follows it in the bindings' scope;
    /// any other is the loop's continue expression, which runs after the
    /// bindings end, also after a `continue` in the condition.
    fn emitWhile(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const cond = ir.While.cond(sexp);
        const step = ir.While.step(sexp);
        lp.target.step_point = if (step == .nil) null else try self.need(self.facts.stepPoint(sexp), sexp);
        const step_inside = lp.target.step_point == .after_body;
        try self.startLoopLine(lp);
        try self.enterLoop(lp);
        const l = try self.openLabeled(lp.loop);
        try self.w.writeAll("while (true) ");
        // Zig runs a continue expression after the body: what its units
        // trace goes after the body's.
        var step_trace: std.ArrayList(UnitEvent) = .empty;
        defer step_trace.deinit(self.allocator);
        const trace = self.unit_trace;
        if (step != .nil and !step_inside) {
            try self.w.writeAll(": (");
            if (lp.turns) |n| try self.w.print("{{ rig.turn(&{s}); ", .{n});
            if (trace != null) self.unit_trace = &step_trace;
            defer self.unit_trace = trace;
            try self.emitStep(step, lp);
            if (lp.turns != null) try self.w.writeAll(" }");
            try self.w.writeAll(") ");
        } else try self.writeStep(lp, "");
        try self.openBrace();
        // `while true` has no condition to fail.
        const always = cond == .src and std.mem.eql(u8, self.srcText(cond), "true");
        const parts: []const Sexp = if (always) &.{} else try self.conditionParts(cond);
        // A part `s as .circle(r)` nests the rest in its `match`, and a
        // value it does not match leaves the loop (`emitChain`).
        if (!always and try self.hasAsMatch(cond)) {
            const End = struct {
                lp: *Loop,
                sexp: Sexp,
                step_inside: bool,
                trace: ?*std.ArrayList(UnitEvent),
                step_trace: *std.ArrayList(UnitEvent),
                fn run(c: *const @This(), e: *Emitter) Error!void {
                    try e.writeIndent(e.indent);
                    const body = try e.openLoopBody(c.lp);
                    try e.closeLoopBody(c.lp, body, ir.While.body(c.sexp));
                    try e.w.writeAll("\n");
                    if (c.trace) |t| try t.appendSlice(e.allocator, c.step_trace.items);
                    if (c.step_inside) {
                        try e.writeIndent(e.indent);
                        try e.emitStep(ir.While.step(c.sexp), c.lp);
                        try e.w.writeAll("\n");
                    }
                }
            };
            const end: End = .{ .lp = lp, .sexp = sexp, .step_inside = step_inside, .trace = trace, .step_trace = &step_trace };
            try self.emitChain(parts, 0, &end, "break");
            try self.closeBrace();
            return self.closeLabeled(l);
        }
        var opened: usize = 0;
        for (parts) |p| {
            try self.writeIndent(self.indent);
            if (rig.isAsPart(p)) {
                try self.w.writeAll("if ");
                const prelude = try self.emitCond(p);
                try self.openBrace();
                try self.emitPrelude(prelude);
                opened += 1;
            } else {
                try self.w.writeAll("if (!(");
                const entered = try self.enterUnit(p);
                defer self.leaveUnit(entered);
                try self.emitHeader(p);
                try self.w.writeAll(")) break;\n");
            }
        }
        try self.writeIndent(self.indent);
        const body = try self.openLoopBody(lp);
        try self.closeLoopBody(lp, body, ir.While.body(sexp));
        try self.w.writeAll("\n");
        if (trace) |t| try t.appendSlice(self.allocator, step_trace.items);
        if (step != .nil and step_inside) {
            try self.writeIndent(self.indent);
            try self.emitStep(step, lp);
            try self.w.writeAll("\n");
        }
        for (0..opened) |_| {
            try self.closeBrace();
            try self.w.writeAll(" else break;\n");
        }
        try self.closeBrace();
        try self.closeLabeled(l);
    }

    /// The step of `while` loop `lp`: a statement, so an assignment drops
    /// the value it replaces, in a block a `continue` in it leaves, which
    /// ends the step.
    fn emitStep(self: *Emitter, step: Sexp, lp: *Loop) Error!void {
        const label = try self.newLabel("step");
        const t = &self.targets.items[lp.index];
        const saved = t.part;
        t.part = .step;
        t.step = label;
        defer {
            self.targets.items[lp.index].part = saved;
            self.targets.items[lp.index].step = null;
        }
        const l = try self.openLabeled(label);
        try self.w.writeAll("{ ");
        try self.emitStmt(step);
        try self.w.writeAll(" }");
        try self.closeLabeled(l);
    }

    fn usesSymbol(self: *Emitter, node: Sexp, sym: SymbolId) bool {
        if (node == .src) return if (self.facts.symbolOf(node)) |s| s == sym else false;
        if (node != .list) return false;
        for (node.items()) |c| if (self.usesSymbol(c, sym)) return true;
        return false;
    }

    /// A loop used as a value: its block (`emitLoop`) gives it the value
    /// of the `break` that leaves it, or of its `else`.
    ///
    ///     @as(T, __rig_loop_N: {
    ///         for (xs) |x| { ... break :__rig_loop_N v; ... }
    ///         break :__rig_loop_N else_value;
    ///     })
    fn emitLoopValue(self: *Emitter, sexp: Sexp) Error!void {
        const labeled = sexp.isKind(.labeled);
        const loop = if (labeled) ir.Labeled.stmt(sexp) else sexp;
        const ty = self.typeOf(loop) orelse return self.unsupported(sexp, "an untyped loop value");
        self.stmt = sexp;
        try self.writeAsOpen(ty);
        try self.emitLoop(loop, if (labeled) self.srcText(ir.Labeled.label(sexp)) else "", ty);
        try self.w.writeAll(")");
    }

    /// The index binding of `for x, i in ...` when the body reads it.
    fn loopIndex(self: *Emitter, sexp: Sexp) ?SymbolId {
        const sym = self.facts.symbolOf(ir.For.index(sexp)) orelse return null;
        return if (self.usage.used.contains(sym)) sym else null;
    }

    /// `const i: Int = @as(i64, @bitCast(@as(u64, counter)));` at the top of a
    /// loop body. The counter is an index below a length: a length is at
    /// most `maxInt(isize)` on a 64-bit target and below 2^32 on a 32-bit
    /// one, so it fits `u64` (a widening, the identity on 64-bit) and its
    /// bits read as `i64` are exact on every target, with no per-iteration
    /// check.
    fn bindLoopIndex(self: *Emitter, sexp: Sexp, counter: []const u8) Error!void {
        const sym = self.loopIndex(sexp) orelse return;
        const local = try self.declare(.{ .sym = sym, .ty = self.symType(sym) }, self.srcText(ir.For.index(sexp)));
        try self.line("const {s}: {s} = @as({s}, @bitCast(@as(u64, {s})));", .{ local.zig_name, int_zig, int_zig, counter });
    }

    /// `(for mode binding index-binding source body else?)` (`emitLoop`):
    /// Zig's own `for`, or a `while` over an iterator or a range, whose
    /// body's block binds the element. The source is evaluated before the
    /// loop is entered, so a jump in it targets the loop around this one.
    fn emitFor(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const mode = ir.For.mode(sexp).tag;
        const binding = ir.For.@"var"(sexp);
        const source = ir.For.source(sexp);
        if (source.isKind(.@"..")) return self.emitRangeFor(sexp, lp);

        const src_ty = self.typeOf(source);
        const is_list = src_ty != null and (self.isListTy(src_ty.?) or self.facts.tableElem(self.peelViews(src_ty.?)) != null);
        // A List or an array of values that move, which the loop takes or
        // its source makes, hands its elements over one at a time.
        if (try self.need(self.facts.forConsumes(sexp), sexp)) return self.emitConsumingFor(sexp, lp, !is_list);
        const elem_sym = self.facts.symbolOf(binding);
        const elem_ty: ?TypeId = if (elem_sym) |s| self.symType(s) else null;
        const header = self.facts.headerOf(sexp);
        // A source with temporaries that reaches no place is walked as a
        // copy, which the checker records (`copiesHeader`).
        if (mode != .move and header != .taken and !rig.isRangeIndex(source)) _ = try self.copiesSubject(sexp, source);
        // An array the loop takes is held in a `var`, and each element is
        // reached through a pointer into it, as the body's own.
        const owned = header == .taken;
        // A resource element is a view of its slot; an element that is
        // itself a read view is the view, copied.
        const elem_is_view = if (src_ty) |t| if (self.loopElem(t)) |e| e == elem_ty else false else false;
        // A binding that is the bytes of a String element walks the elements
        // by address and takes each one's bytes.
        const string_bytes = self.facts.loopBindsStringBytes(sexp);
        const by_ptr = mode == .write or owned or string_bytes or
            (elem_ty != null and self.facts.types.get(elem_ty.?) == .read_view and !elem_is_view);

        // A value the loop holds, or the array it takes, lives in the
        // block around it.
        var taken: []const u8 = "";
        var mark: ?usize = null;
        if (owned or header == .held) {
            try self.openLoopBlock(lp);
            if (header == .held) mark = try self.emitHeld(sexp);
            if (owned) {
                taken = try self.hiddenStorage(sexp, .taken, .owned, .next);
                try self.writeIndent(self.indent);
                try self.w.print("var {s} = ", .{taken});
                try self.emitHeader(source);
                try self.w.writeAll(";\n");
            }
        }
        defer if (mark) |m| self.hoisted.shrinkRetainingCapacity(m);
        try self.startLoopLine(lp);
        try self.pushScope();
        const l = try self.openLabeled(lp.loop);
        // Zig's `for` has no continue expression: each turn's body
        // counts it.
        lp.top_turn = true;
        try self.w.writeAll("for (");
        // Writing an array's elements in place iterates through a pointer.
        const array_ptr = by_ptr and !is_list and src_ty != null and self.facts.types.get(self.peelViews(src_ty.?)) == .array;
        if (owned) try self.w.print("&{s}", .{taken}) else if (try self.headerPoints(source)) {
            // A place reached through temporaries is walked where it is.
            try self.emitSubjectPtr(source, mode == .write);
            if (!array_ptr) try self.w.writeAll(".*");
        } else if (array_ptr) try self.emitAddressOf(source) else {
            const h = try self.openHeader(source);
            try self.emitExpr(source);
            try self.closeHeader(h);
        }
        if (is_list) try self.w.writeAll(".items()");
        // `for b in ?t` walks the bytes of a String, boxed or not.
        if (src_ty) |t| if (self.stringReach(t)) |reach| try self.w.print("{s}.bytes()", .{reach});
        const counter = try self.fmt("__rig_i_{d}", .{self.nextId()});
        // An index nobody reads needs no counter.
        const indexed = self.loopIndex(sexp) != null;
        try self.w.writeAll(if (indexed) ", 0..) |" else ") |");
        var elem_name: []const u8 = "_";
        var bytes_of: []const u8 = "";
        var bytes_name: []const u8 = "";
        if (elem_sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .ty = elem_ty, .is_ptr = by_ptr and !string_bytes }, self.srcText(binding));
            if (string_bytes) {
                bytes_of = try self.hiddenStorage(sexp, .element, .pointer, .next);
                bytes_name = stored.zig_name;
                elem_name = try self.fmt("*{s}", .{bytes_of});
            } else elem_name = try self.fmt("{s}{s}", .{ if (by_ptr) "*" else "", stored.zig_name });
        };
        try self.w.print("{s}{s}{s}| ", .{ elem_name, if (indexed) ", " else "", if (indexed) counter else "" });
        try self.enterLoop(lp);
        const body = try self.openLoopBody(lp);
        if (bytes_of.len > 0) try self.line("const {s} = {s}.bytes();", .{ bytes_name, bytes_of });
        try self.bindLoopIndex(sexp, counter);
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
        try self.popScope();
    }

    /// `for x in <v`: the List (or the array, `array`) is consumed; each
    /// element is handed to `x`, which owns it for one iteration.
    /// Elements a `break` or `return` leaves behind are dropped with it.
    ///
    ///     { var it = v.intoIter(); defer it.deinit();
    ///       while (it.next()) |e| { var x = e; defer rig.drop(&x); ... } }
    fn emitConsumingFor(self: *Emitter, sexp: Sexp, lp: *Loop, array: bool) Error!void {
        const binding = ir.For.@"var"(sexp);
        const id = self.nextId();
        const it = try self.hiddenStorage(sexp, .iterator, .owned, .{ .id = id });
        const tmp = try self.hiddenStorage(sexp, .element, .owned, .{ .id = id });
        const counter = try self.fmt("__rig_i_{d}", .{id});
        const indexed = self.loopIndex(sexp) != null;

        try self.openLoopBlock(lp);
        try self.writeIndent(self.indent);
        try self.w.print("var {s} = {s}(", .{ it, if (array) "rig.arrayIntoIter" else "" });
        const h = try self.openHeader(ir.For.source(sexp));
        try self.emitMoved(ir.For.source(sexp));
        try self.closeHeader(h);
        try self.w.writeAll(if (array) ");\n" else ").intoIter();\n");
        try self.line("defer {s}.deinit();", .{it});
        if (indexed) try self.line("var {s}: usize = 0;", .{counter});
        try self.startLoopLine(lp);
        try self.enterLoop(lp);
        const l = try self.openLabeled(lp.loop);
        const elem = if (self.typeOf(ir.For.source(sexp))) |t| self.loopElem(t) else null;
        if (elem != null and self.routesPayload(elem.?)) {
            try self.w.print("while (rig.some({s}.next())) |{s}| ", .{ it, tmp });
        } else try self.w.print("while ({s}.next()) |{s}| ", .{ it, tmp });
        try self.writeStep(lp, if (indexed) try self.fmt("{s} += 1", .{counter}) else "");
        const body = try self.openLoopBody(lp);
        const sym = self.facts.symbolOf(binding);
        const ty: ?TypeId = if (sym) |s| self.symType(s) else null;
        if (sym != null and self.holdOf(sym.?) != null) {
            try self.bindOptionalResource(.{ .cond = sexp, .name = binding, .tmp = tmp });
        } else if (sym != null and self.usage.used.contains(sym.?)) {
            const local = try self.declare(.{ .sym = sym.?, .ty = ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ local.zig_name, tmp });
        } else try self.line("_ = {s};", .{tmp});
        try self.bindLoopIndex(sexp, counter);
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
    }

    /// `for i in a..b`: a half-open integer range. `a..=b` includes its
    /// end, which may be the type's largest value, so its counter is
    /// stepped only while it is below the end, and a flag ends the loop.
    fn emitRangeFor(self: *Emitter, sexp: Sexp, lp: *Loop) Error!void {
        const binding = ir.For.@"var"(sexp);
        const range = ir.For.source(sexp);
        const id = self.nextId();
        const counter = try self.hiddenStorage(sexp, .range_start, .owned, .{ .id = id });
        const end = try self.hiddenStorage(sexp, .range_end, .owned, .{ .id = id });
        const sym = self.facts.symbolOf(binding);
        const int_ty: TypeId = if (sym) |s| (self.symType(s) orelse self.facts.types.int_id) else self.facts.types.int_id;

        try self.openLoopBlock(lp);
        for ([2][]const u8{ counter, end }, [2]Sexp{ ir.@"..".left(range), ir.@"..".right(range) }, [2][]const u8{ "var", "const" }) |name, bound, decl| {
            try self.writeIndent(self.indent);
            try self.w.print("{s} {s}: ", .{ decl, name });
            try self.emitTypeTy(int_ty);
            try self.w.writeAll(" = ");
            try self.emitHeader(bound);
            try self.w.writeAll(";\n");
        }
        const more = if (rig.isInclusive(range)) try self.hiddenStorage(sexp, .range_more, .owned, .{ .id = id }) else "";
        if (more.len > 0) try self.line("var {s} = {s} <= {s};", .{ more, counter, end });
        try self.startLoopLine(lp);
        try self.enterLoop(lp);
        const l = try self.openLabeled(lp.loop);
        if (more.len > 0) {
            try self.w.print("while ({s}) ", .{more});
            try self.writeStep(lp, try self.fmt("{s} = {s} < {s}; {s} +%= 1;", .{ more, counter, end, counter }));
        } else {
            try self.w.print("while ({s} < {s}) ", .{ counter, end });
            try self.writeStep(lp, try self.fmt("{s} += 1", .{counter}));
        }
        const body = try self.openLoopBody(lp);
        if (sym) |s| if (self.usage.used.contains(s)) {
            const stored = try self.declare(.{ .sym = s, .ty = int_ty }, self.srcText(binding));
            try self.line("const {s} = {s};", .{ stored.zig_name, counter });
        };
        try self.closeLoopBody(lp, body, ir.For.body(sexp));
        try self.closeLabeled(l);
    }

    // -------------------------------------------------------------------------
    // Match
    // -------------------------------------------------------------------------

    /// How a match reaches its subject (`facts.MatchMode`).
    const MatchMode = facts.MatchMode;

    /// What `emitMatch` knows about a match's subject.
    const MatchInfo = struct {
        match: Sexp,
        mode: MatchMode,
        /// The type matched: the enum a boxed subject holds.
        ty: ?TypeId,
        error_set: bool,
        /// The subject without its `?` / `!`.
        subject: Sexp,
        boxed: bool,
        /// The subject as Zig that reads it again without evaluating it
        /// again (`evalSubject`), or empty when nothing reads it twice.
        reread: []const u8 = "",
        /// A `match <x` of a value no binding holds: it was evaluated
        /// into `reread`, which the arm then takes.
        temp: bool = false,
        /// A read match switches on its subject where it is
        /// (`storage.matchesInPlace`).
        in_place: bool = false,
    };

    /// Whether the field or element path `e` passes through an element.
    fn throughElement(e: Sexp) bool {
        var p = e;
        while (p.isKind(.member) or p.isKind(.index)) : (p = ir.get(p, .object)) {
            if (p.isKind(.index)) return true;
        }
        return false;
    }

    /// `(match scrutinee arm...)` → `switch`. In value position each arm
    /// yields a value. A match with a guarded arm, or on text, picks its
    /// arm first (`emitGuardedMatch`).
    /// `hook`, when not `null`, writes each arm's block in place of its
    /// body, by `hook.arm(emitter, index, prelude)`: the arms of the
    /// `match` an `as` with a pattern is (`emitChain`).
    fn emitMatch(self: *Emitter, sexp: Sexp, value_pos: bool, hook: anytype) Error!void {
        const scrutinee = ir.Match.subject(sexp);
        // An enum in a box or behind a handle is switched on where it is.
        const scrut_ty = self.facts.matchedType(sexp);
        var info: MatchInfo = .{
            .match = sexp,
            .mode = try self.need(self.facts.matchMode(sexp), sexp),
            .ty = scrut_ty,
            .error_set = if (scrut_ty) |t| self.isErrorSetTy(t) else false,
            // `match ?t` / `match !t` switch on the value viewed.
            .subject = lentPlace(scrutinee),
            .boxed = scrut_ty != null and scrut_ty.? != self.typeOf(scrutinee).?,
            .in_place = try self.need(self.facts.matchesInPlace(sexp), sexp),
        };
        // A subject with temporaries that reaches no place is matched as
        // a copy, which the checker records (`copiesHeader`).
        const held_view = try self.need(self.facts.holdsView(sexp), sexp);
        if (info.mode != .consume and !held_view) _ = try self.copiesSubject(sexp, info.subject);
        const guarded = self.facts.matchSelects(sexp);
        // A `match !x` binding of the whole value points at the place, and
        // a `match <x` arm with alternatives drops the value from it: the
        // subject is read again.
        const rereads = try self.need(self.facts.matchRereads(sexp), sexp);
        // Evaluating the subject first, or holding the value it is a part
        // of (`Header.held`), takes a block around the match.
        const held = self.facts.headerOf(sexp) == .held;
        const block = if (try self.need(self.facts.matchBlock(sexp), sexp)) try self.fmt("__rig_match_{d}", .{self.nextId()}) else "";
        var held_mark: ?usize = null;
        defer if (held_mark) |m| self.hoisted.shrinkRetainingCapacity(m);
        if (block.len > 0) {
            if (value_pos) try self.w.print("{s}: ", .{block});
            try self.openBrace();
            if (held) held_mark = try self.emitHeld(sexp);
            try self.evalSubject(&info);
            if (guarded) {
                try self.emitGuardedMatch(sexp, value_pos, info, block);
                try self.w.writeAll("\n");
                return self.closeBrace();
            }
            try self.writeIndent(self.indent);
            if (value_pos) try self.w.print("break :{s} ", .{block});
        } else if (rereads) info.reread = try self.placeText(info);
        // An error that carries fields is switched on by its code, and
        // read again through its place for its fields.
        const err_value = info.error_set and info.ty != null and self.isErrorValueTy(self.peelViews(info.ty.?));
        if (err_value and info.reread.len == 0) info.reread = try self.placeText(info);
        const place = info.reread;
        const subject = info.subject;
        try self.w.writeAll("switch (");
        if (err_value and info.mode == .consume and !info.temp) {
            // `match <e` takes the error as it tests its code; each arm
            // then owns what it reads again through the place.
            var buf: Writer.Allocating = .init(self.arena.allocator());
            {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                try self.emitBare(subject);
            }
            try self.writeErrorCode(info.ty.?, buf.written());
        } else if (err_value) {
            try self.writeErrorCode(info.ty.?, place);
        } else if (info.temp or (info.reread.len > 0 and info.mode != .consume)) {
            try self.w.writeAll(info.reread);
        } else if (try self.headerPoints(subject)) {
            // A place reached through temporaries is switched on where it
            // is, so each payload captured by pointer is the place's own.
            try self.emitSubjectPtr(subject, info.mode == .write);
            try self.w.writeAll(".*");
            if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        } else if (info.mode == .write and try self.need(self.facts.handsOver(subject), subject) == .place and throughElement(subject)) {
            // A place through an element that a write match writes is
            // switched on where it is (a List's element reads as a
            // value): `(&v.slot(i).*).*`.
            try self.w.writeAll("(");
            try self.emitSubjectPtr(subject, true);
            try self.w.writeAll(").*");
            if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        } else {
            // A match on a call returning a view held by pointer
            // switches on the value it points to, where it is: a header
            // with temporaries yields the pointer, never the value.
            const by_ptr = !(try self.hasStorage(subject)) and self.isPtrViewExpr(subject);
            const h = try self.openHeader(subject);
            if (by_ptr and h.label.len > 0) {
                try self.emitWriteViewPtr(subject);
                try self.closeHeader(h);
                try self.w.writeAll(".*");
            } else {
                if (by_ptr or self.switchesThroughName(subject)) try self.emitSwitchDeref(subject) else {
                    const saved_path = self.subject_path;
                    defer self.subject_path = saved_path;
                    self.subject_path = subject;
                    // A value built of constants is switched on at run
                    // time: its payloads are not constants.
                    const fixed = info.mode == .read and !info.boxed and isZigComptimeIn(self, subject, 0);
                    try self.openFixed(fixed, subject);
                    try self.emitBare(subject);
                    try self.closeFixed(fixed, subject);
                }
                if (info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
                try self.closeHeader(h);
            }
            if (by_ptr and h.label.len > 0 and info.boxed) try self.writeMatchReach(self.typeOf(subject).?);
        }
        try self.w.writeAll(") ");
        try self.openBrace();

        var has_default = false;
        for (ir.Match.arms(sexp), 0..) |arm, arm_i| {
            const pattern = ir.Arm.pattern(arm);
            const body = ir.Arm.body(arm);
            try self.writeIndent(self.indent);
            try self.pushScope();
            defer self.popScope() catch {};

            var prelude: Prelude = .{};
            if (self.isCatchAll(pattern)) {
                has_default = true;
                try self.w.writeAll("else => ");
                const named = !std.mem.eql(u8, self.srcText(pattern), "_");
                if (err_value and info.mode != .consume) {
                    // The whole error, read where it is.
                    if (named) prelude.aliases = try self.wholeAlias(pattern, place, body);
                } else switch (info.mode) {
                    .read => if (named) try self.emitCapture(pattern),
                    .write => if (named) {
                        prelude.aliases = try self.wholeAlias(pattern, try self.fmt("&{s}", .{place}), .nil);
                    },
                    .consume => {
                        const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
                        // An error's code is all the switch gives; the
                        // error the match took is read again where it was.
                        if (err_value) prelude.head = try self.fmt("const {s} = {s};", .{ whole, place }) else try self.w.print("|{s}| ", .{whole});
                        const head = prelude.head;
                        prelude = try self.ownedParts(&.{if (named) pattern else .nil}, &.{.{ .expr = whole }}, .nil);
                        prelude.head = head;
                    },
                }
            } else if (pattern.isKind(.set_pattern) and err_value and self.isErrorValueTy(self.peelViews(self.typeOf(pattern) orelse info.ty.?))) {
                // `g: E =>` of an error that carries fields: `g` is the
                // error itself, which every set's value is laid out as;
                // under `match <e`, the arm owns it.
                try self.writePatternHead(pattern, info);
                try self.w.writeAll(" => ");
                if (info.mode == .consume) {
                    const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
                    prelude = try self.ownedParts(&.{ir.SetPattern.name(pattern)}, &.{.{ .expr = whole }}, .nil);
                    prelude.head = try self.fmt("const {s} = {s};", .{ whole, place });
                } else prelude.aliases = try self.wholeAlias(ir.SetPattern.name(pattern), place, body);
            } else if (pattern.isKind(.set_pattern)) {
                // `g: E =>`: `g` is the prong's capture, which Zig gives
                // the set of the members the prong lists, a subset of `E`.
                try self.writePatternHead(pattern, info);
                try self.w.writeAll(" => ");
                const name = ir.SetPattern.name(pattern);
                const cap = try self.fmt("__rig_set_{d}", .{name.src.pos});
                var buf: Writer.Allocating = .init(self.arena.allocator());
                {
                    const saved_w = self.w;
                    self.w = &buf.writer;
                    defer self.w = saved_w;
                    try self.w.writeAll("@as(");
                    try self.emitTypeTy(self.typeOf(pattern) orelse return self.unsupported(pattern, "an untyped set pattern"));
                    try self.w.print(", {s})", .{cap});
                }
                prelude.aliases = try self.wholeAlias(name, buf.written(), ir.Arm.body(arm));
                if (prelude.aliases.len > 0) try self.w.print("|{s}| ", .{cap});
            } else {
                try self.writePatternHead(pattern, info);
                try self.w.writeAll(" => ");
                const captures: []const Sexp = if (pattern.isKind(.variant_pattern)) self.facts.payloadBindings(pattern) orelse &.{} else &.{};
                // The one member a pattern names: a variant, or an error
                // set's member (`E.name`); none for alternatives.
                const vname: []const u8 = if (pattern.isKind(.variant_pattern)) self.srcText(rig.variantPatternName(pattern)) else if (pattern.isKind(.enum_lit) or pattern.isKind(.member)) self.srcText(ir.get(pattern, .name)) else "";
                // The arm's own set, where the subject may be of several.
                var arm_info = info;
                if (info.error_set) arm_info.ty = self.typeOf(pattern) orelse info.ty;
                if (info.mode == .consume) {
                    // The arm owns the value: each field is bound or
                    // dropped at the end of the arm.
                    const fields = if (vname.len > 0) self.variantPayload(arm_info.ty.?, vname) orelse &.{} else &.{};
                    if (vname.len == 0) {
                        // Alternatives: the value is dropped from where it
                        // was, copied before the arm can reassign it.
                        const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
                        prelude = try self.ownedParts(&.{.nil}, &.{.{ .expr = whole }}, .nil);
                        prelude.head = try self.fmt("const {s} = {s};", .{ whole, place });
                    } else if (fields.len > 0 and err_value) {
                        // A member's fields, taken from the error's bytes.
                        const payload = try self.hiddenStorage(arm, .payload, .owned, .fresh);
                        prelude = try self.consumedPayload(captures, fields, payload, .nil);
                        var buf: Writer.Allocating = .init(self.arena.allocator());
                        {
                            const saved_w = self.w;
                            self.w = &buf.writer;
                            defer self.w = saved_w;
                            try self.w.print("const {s} = {s}.fieldsAs(", .{ payload, place });
                            try self.emitMemberFieldsTy(arm_info.ty.?, vname);
                            try self.w.writeAll(").*;");
                        }
                        prelude.head = buf.written();
                    } else if (fields.len > 0) {
                        const payload = try self.hiddenStorage(arm, .payload, .owned, .fresh);
                        try self.w.print("|{s}| ", .{payload});
                        prelude = try self.consumedPayload(captures, fields, payload, .nil);
                    }
                } else if (captures.len > 0 and err_value) {
                    // A member's fields, read in place from the error.
                    const set = self.typeOf(pattern) orelse info.ty.?;
                    var buf: Writer.Allocating = .init(self.arena.allocator());
                    {
                        const saved_w = self.w;
                        self.w = &buf.writer;
                        defer self.w = saved_w;
                        try self.w.print("{s}.fieldsAs(", .{place});
                        try self.emitMemberFieldsTy(set, vname);
                        try self.w.writeAll(")");
                    }
                    prelude.aliases = try self.payloadAliases(captures, arm_info, vname, .{ .expr = buf.written() }, .nil);
                } else if (captures.len > 0) {
                    prelude.aliases = try self.payloadAliases(captures, info, vname, .{ .arm = arm }, .nil);
                    // A payload a read binds as a view is reached in place.
                    const by_ptr = info.mode == .write or for (prelude.aliases) |a| {
                        if (a.addr) break true;
                    } else false;
                    if (prelude.aliases.len > 0) try self.w.print("|{s}{s}| ", .{ if (by_ptr) "*" else "", prelude.aliases[0].payload });
                }
            }
            // An arm runs after the selection.
            // A hook's arms end the selection themselves (`ChainArms`).
            const paused = if (@TypeOf(hook) != @TypeOf(null)) false else try self.pauseUnit(sexp);
            if (@TypeOf(hook) != @TypeOf(null)) {
                try hook.arm(self, arm_i, prelude);
            } else if (value_pos) try self.emitValueBlock(body, prelude, self.typeOf(sexp)) else try self.emitBodyWith(body, prelude);
            try self.resumeUnit(sexp, paused);
            try self.w.writeAll(",\n");
        }
        try self.closeBrace();
        if (block.len > 0) {
            if (value_pos) try self.w.writeAll(";");
            try self.w.writeAll("\n");
            try self.closeBrace();
        }
    }

    /// `facts.syntax.subjectRereadable`.
    fn subjectRereadable(self: *Emitter, info: MatchInfo) bool {
        _ = self;
        return facts.syntax.subjectRereadable(info.subject);
    }

    /// Evaluate the subject once, into `info.reread`: a field path as
    /// it is, an element by its address, a value no binding holds (a
    /// call's result, or what `match <` takes from one) into a local.
    fn evalSubject(self: *Emitter, info: *MatchInfo) Error!void {
        const by = (try self.need(self.facts.subjectHold(info.match), info.match)) orelse {
            info.reread = try self.placeText(info.*);
            return;
        };
        const name = try self.hiddenStorage(info.match, .subject, by, .next);
        const value = if (info.subject.isKind(.move)) ir.Move.operand(info.subject) else info.subject;
        if ((try self.hasStorage(value)) and !info.subject.isKind(.move) and !self.hasTemps(value)) {
            // Read by no arm (`_ => 1`), the subject is still evaluated
            // once, for its index's test: the discard keeps Zig from
            // rejecting an unused constant.
            try self.line("const {s} = &{s}; _ = &{s};", .{ name, try self.placeText(info.*), name });
            info.reread = try self.fmt("{s}.*", .{name});
            return;
        }
        // A place reached through temporaries is held as its address,
        // which the header's block yields, and a view a call returns
        // (`match get(e)`) as the pointer it is, never copied: the
        // bindings view the value it points to.
        const points = try self.headerPoints(value);
        if (!info.subject.isKind(.move) and (points or self.isPtrViewExpr(value))) {
            try self.writeIndent(self.indent);
            try self.w.print("const {s} = ", .{name});
            if (points) try self.emitSubjectPtr(value, info.mode == .write) else {
                const h = try self.openHeader(value);
                try self.emitWriteViewPtr(value);
                try self.closeHeader(h);
            }
            try self.w.print("; _ = &{s};\n", .{name});
            var buf: Writer.Allocating = .init(self.arena.allocator());
            {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                // A generic read view is reached where it points, or
                // where its instance's copy is held (`rig.viewedPtr`).
                if (self.genericReadViewOf(value)) |inner| {
                    try self.w.writeAll("rig.viewedPtr(");
                    try self.emitTypeTy(inner);
                    try self.w.print(", &{s}).*", .{name});
                } else try self.w.print("{s}.*", .{name});
                if (info.boxed) try self.writeMatchReach(self.typeOf(value).?);
            }
            info.reread = buf.written();
            return;
        }
        try self.writeIndent(self.indent);
        try self.w.print("var {s}", .{name});
        if (self.typeOf(value)) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(self.peelViews(t));
        }
        try self.w.writeAll(" = ");
        const h = try self.openHeader(value);
        if (self.isPtrViewExpr(value)) try self.emitDeref(value) else try self.emitBare(value);
        if (info.boxed and self.hasTemps(value)) try self.w.writeAll(".value.*");
        try self.closeHeader(h);
        try self.w.print("; _ = &{s};\n", .{name});
        try self.poisonAtExit(name);
        info.reread = name;
        info.temp = info.mode == .consume;
    }

    /// Whether `e` is the `match` subject being emitted, or a field or
    /// element path on the way to it from the name it starts at
    /// (`subject_path`).
    fn onSubjectPath(self: *const Emitter, e: Sexp) bool {
        var p = self.subject_path;
        while (p != .nil) {
            if (p.isKind(.move) or p.isKind(.read) or p.isKind(.write)) {
                p = ir.get(p, .operand);
                continue;
            }
            if (sameNode(p, e)) return true;
            if (!p.isKind(.member) and !p.isKind(.index)) return false;
            p = ir.get(p, .object);
        }
        return false;
    }

    /// `rig.viewedPtr(T, &view).*`: the `T` a generic read view held at
    /// `view`, a name, a field, or an element, reaches in place: the
    /// value the view points to, or the copy it holds. The caller writes
    /// `view` between `open` and `close`.
    fn writeViewedPtrOpen(self: *Emitter, inner: TypeId) Error!void {
        try self.w.writeAll("rig.viewedPtr(");
        try self.emitTypeTy(inner);
        try self.w.writeAll(", &");
    }

    /// The Zig place of a match's subject, for `match !x` and `match <x`
    /// (whose subject is a binding).
    fn placeText(self: *Emitter, info: MatchInfo) Error![]const u8 {
        var buf: Writer.Allocating = .init(self.arena.allocator());
        const saved_w = self.w;
        self.w = &buf.writer;
        defer self.w = saved_w;
        const saved_path = self.subject_path;
        defer self.subject_path = saved_path;
        self.subject_path = info.subject;
        try self.emitPlace(if (info.subject.isKind(.move)) ir.Move.operand(info.subject) else info.subject);
        if (info.boxed) try self.writeMatchReach(self.typeOf(info.subject).?);
        return buf.written();
    }

    /// The enum a match on a `ty` in a box or behind a handle switches
    /// on: `.value` for each box (a pointer) and handle on the way, the
    /// value itself at the end.
    fn writeMatchReach(self: *Emitter, ty: TypeId) Error!void {
        var t = self.facts.unwrapViews(ty);
        var ptr = false;
        while (true) {
            switch (self.facts.types.get(t)) {
                .shared => |inner| {
                    try self.w.writeAll(if (ptr) ".*.value" else ".value");
                    t = self.facts.unwrapViews(inner);
                    ptr = false;
                    continue;
                },
                else => {},
            }
            const inner = self.facts.boxedType(t) orelse break;
            try self.w.writeAll(".value");
            // A view the box holds is a pointer to the value.
            if (self.isPtrViewTy(inner)) try self.w.writeAll(".*");
            t = self.facts.unwrapViews(inner);
            ptr = true;
        }
        if (ptr) try self.w.writeAll(".*");
    }

    /// The prong head of a pattern that is not a catch-all: a literal, a
    /// variant, a range, or alternatives.
    fn writePatternHead(self: *Emitter, pattern: Sexp, info: MatchInfo) Error!void {
        // A member of an error set is matched by its code.
        const saved_codes = self.error_codes;
        defer self.error_codes = saved_codes;
        if (info.error_set) self.error_codes = true;
        if (pattern.isKind(.alt_pattern)) {
            for (ir.AltPattern.alts(pattern), 0..) |alt, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.writePatternHead(alt, info);
            }
            return;
        }
        // `g: E =>`: each member of every set `E` stands for.
        if (pattern.isKind(.set_pattern)) {
            const members = (try self.facts.setPatternMembers(pattern, self.arena.allocator())) orelse return self.unsupported(pattern, "an unchecked set pattern");
            for (members, 0..) |m, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.w.writeAll("error.");
                try writeErrorName(self.w, m.facts, m.set, m.name);
            }
            return;
        }
        // A member of an error set with fields, by its code.
        if (pattern.isKind(.variant_pattern) and info.error_set) {
            return self.writeError(self.typeOf(pattern) orelse info.ty.?, self.srcText(rig.variantPatternName(pattern)), pattern);
        }
        if (pattern.isKind(.enum_lit) and info.error_set) {
            // Sema gave `.name` against an error the type of its set.
            return self.writeError(self.typeOf(pattern) orelse return self.unsupported(pattern, "an untyped error"), self.srcText(ir.EnumLit.name(pattern)), pattern);
        }
        if (pattern.isKind(.enum_lit) or pattern.isKind(.variant_pattern)) {
            return self.w.print(".{f}", .{ident(self.srcText(ir.get(pattern, .name)))});
        }
        if (pattern.isKind(.range_pattern)) {
            // `lo..hi` is half-open, `lo..=hi` inclusive; Zig's
            // `lo...hi` is inclusive. Sema
            // checked both bounds are constants.
            const b = try self.rangeBounds(pattern);
            return self.w.print("{d}...{d}", .{ b[0], b[1] });
        }
        // A constant's name compares with its value.
        if (self.facts.patternConst(pattern)) |value| return switch (value) {
            .int => |v| self.w.print("{d}", .{v}),
            .boolean => |b| self.w.writeAll(if (b) "true" else "false"),
            .variant => |name| self.w.print(".{f}", .{ident(name)}),
        };
        try self.emitExpr(pattern);
    }

    /// The inclusive bounds of range pattern `lo..hi` or `lo..=hi`.
    fn rangeBounds(self: *Emitter, pattern: Sexp) Error![2]Wide {
        const lo = self.facts.constIntOf(ir.RangePattern.lo(pattern)) orelse return self.unsupported(pattern, "this range pattern");
        const hi = self.facts.constIntOf(ir.RangePattern.hi(pattern)) orelse return self.unsupported(pattern, "this range pattern");
        return .{ lo, if (rig.isInclusive(pattern)) hi else hi - 1 };
    }

    /// `storage.isCatchAll`.
    fn isCatchAll(self: *Emitter, pattern: Sexp) bool {
        return self.facts.isCatchAll(pattern);
    }

    /// `x => ...` binding the whole value as `expr`, when the arm uses it
    /// (in `used_in`, when given).
    fn wholeAlias(self: *Emitter, pattern: Sexp, expr: []const u8, used_in: Sexp) Error![]const Alias {
        const local = self.usedPayloadLocal(pattern, used_in) orelse return &.{};
        const stored = try self.declare(local, self.srcText(pattern));
        return self.arena.allocator().dupe(Alias, &.{.{ .zig_name = stored.zig_name, .payload = expr, .field = "" }});
    }

    /// The catch-all binding `pattern` of the matched value `subj`, used
    /// in `used_in`: its address for a write view, and for a read one
    /// captured by address (`storage.catchAllByAddress`, as `emitCapture`
    /// decides it), the value for a copy.
    fn wholeBinding(self: *Emitter, pattern: Sexp, subj: []const u8, info: MatchInfo, used_in: Sexp) Error![]const Alias {
        const local = self.usedPayloadLocal(pattern, used_in) orelse return &.{};
        const t = local.ty orelse return self.unsupported(pattern, "a catch-all binding of unknown type");
        if (info.mode == .write) return self.wholeAlias(pattern, try self.fmt("&{s}", .{subj}), used_in);
        // A `?String` views the bytes of the text matched.
        if (t == self.facts.types.string_view_id) {
            const stored = try self.declare(payloadPointee(local, false), self.srcText(pattern));
            return self.arena.allocator().dupe(Alias, &.{.{ .zig_name = stored.zig_name, .payload = try self.fmt("rig.stringBytes({s})", .{subj}), .field = "" }});
        }
        const by_addr = try self.need(self.facts.catchAllCaptured(pattern), pattern);
        const stored = try self.declare(payloadPointee(local, by_addr and !self.isPtrViewTy(t)), self.srcText(pattern));
        const expr = if (by_addr) try self.fmt("&{s}", .{subj}) else subj;
        return self.arena.allocator().dupe(Alias, &.{.{ .zig_name = stored.zig_name, .payload = expr, .field = "" }});
    }

    /// The prelude of a `match <x` arm on payload variant `fields`, held
    /// in `payload`: bound fields become owned locals, and the rest is
    /// dropped at the end of the arm.
    fn consumedPayload(self: *Emitter, captures: []const Sexp, fields: []const facts.Field, payload: []const u8, used_in: Sexp) Error!Prelude {
        if (captures.len == 0) return self.ownedParts(&.{.nil}, &.{.{ .expr = payload }}, used_in);
        const parts = try self.arena.allocator().alloc(OwnedPart, fields.len);
        for (fields, parts) |f, *part| part.* = .{ .expr = try self.fmt("{s}.{f}", .{ payload, ident(f.name) }) };
        return self.ownedParts(captures, parts, used_in);
    }

    /// A match with a guarded arm, or on text (`storage.matchSelects`). A
    /// Zig `switch` has no guards and no strings, so the arm is picked
    /// first, trying each in order (a guard sees the bindings it names),
    /// and a `switch` on its index runs it:
    ///     { const arm = sel: { if (s == .a) { const r = s.a.r; if (r > 0) break :sel 0; } ... break :sel N; };
    ///       switch (arm) { 0 => { const r = s.a.r; body }, ..., else => unreachable } }
    /// The subject is read in place, or from a copy when it is not a
    /// place (sema rejects a temporary that owns a resource).
    fn emitGuardedMatch(self: *Emitter, sexp: Sexp, value_pos: bool, info: MatchInfo, block: []const u8) Error!void {
        const id = self.nextId();
        const arms = ir.Match.arms(sexp);
        const subj = info.reread;

        // Pick the arm.
        const arm_var = try self.fmt("__rig_arm_{d}", .{id});
        const sel = try self.fmt("__rig_select_{d}", .{id});
        try self.line("const {s}: usize = {s}: {{", .{ arm_var, sel });
        self.indent += 1;
        var picked = false;
        for (arms, 0..) |arm, i| {
            const pattern = ir.Arm.pattern(arm);
            const guard = ir.Arm.guard(arm);
            const catch_all = self.isCatchAll(pattern);
            try self.writeIndent(self.indent);
            if (!catch_all) {
                try self.w.writeAll("if (");
                try self.writePatternTest(pattern, info, if (self.matchesErrorValue(info)) try self.fmt("{s}.code", .{subj}) else subj);
                try self.w.writeAll(") ");
            }
            if (guard == .nil) {
                try self.w.print("break :{s} @as(usize, {d});\n", .{ sel, i });
                if (catch_all) {
                    picked = true;
                    break;
                }
                continue;
            }
            try self.openBrace();
            try self.guardBindings(pattern, guard, info, subj);
            try self.writeIndent(self.indent);
            try self.w.writeAll("if (");
            try self.emitHeader(guard);
            try self.w.print(") break :{s} @as(usize, {d});\n", .{ sel, i });
            try self.closeBrace();
            try self.w.writeAll("\n");
        }
        if (!picked) try self.line("break :{s} @as(usize, {d});", .{ sel, arms.len });
        self.indent -= 1;
        try self.line("}};", .{});

        // Run it.
        try self.writeIndent(self.indent);
        if (value_pos) try self.w.print("break :{s} ", .{block});
        try self.w.print("switch ({s}) ", .{arm_var});
        try self.openBrace();
        for (arms, 0..) |arm, i| {
            try self.writeIndent(self.indent);
            try self.w.print("{d} => ", .{i});
            try self.pushScope();
            defer self.popScope() catch {};
            const prelude = try self.armBindings(arm, info, subj);
            const paused = try self.pauseUnit(sexp);
            if (value_pos) try self.emitValueBlock(ir.Arm.body(arm), prelude, self.typeOf(sexp)) else try self.emitBodyWith(ir.Arm.body(arm), prelude);
            try self.resumeUnit(sexp, paused);
            try self.w.writeAll(",\n");
        }
        // No arm ran: impossible, since sema requires the arms to cover
        // every value.
        try self.line("else => unreachable,", .{});
        try self.closeBrace();
        if (value_pos) try self.w.writeAll(";");
    }

    /// Whether a match on `info` is on an error that may carry fields,
    /// which it tests by code and reads fields of through its bytes.
    fn matchesErrorValue(self: *Emitter, info: MatchInfo) bool {
        return info.error_set and info.ty != null and self.isErrorValueTy(self.peelViews(info.ty.?));
    }

    /// `subj.fieldsAs(F)`: the fields of `pattern`'s member, read through
    /// the bytes of the error `subj`.
    fn errorFieldsText(self: *Emitter, pattern: Sexp, info: MatchInfo, subj: []const u8) Error![]const u8 {
        var buf: Writer.Allocating = .init(self.arena.allocator());
        const saved_w = self.w;
        self.w = &buf.writer;
        defer self.w = saved_w;
        try self.w.print("{s}.fieldsAs(", .{subj});
        try self.emitMemberFieldsTy(self.typeOf(pattern) orelse info.ty.?, self.srcText(rig.variantPatternName(pattern)));
        try self.w.writeAll(")");
        return buf.written();
    }

    /// A Zig condition that holds when `pattern`, not a catch-all,
    /// matches `subj`.
    fn writePatternTest(self: *Emitter, pattern: Sexp, info: MatchInfo, subj: []const u8) Error!void {
        if (pattern.isKind(.alt_pattern)) {
            try self.w.writeAll("(");
            for (ir.AltPattern.alts(pattern), 0..) |alt, i| {
                if (i > 0) try self.w.writeAll(" or ");
                try self.writePatternTest(alt, info, subj);
            }
            return self.w.writeAll(")");
        }
        if (pattern.isKind(.range_pattern)) {
            const b = try self.rangeBounds(pattern);
            return self.w.print("({s} >= {d} and {s} <= {d})", .{ subj, b[0], subj, b[1] });
        }
        if (pattern.isKind(.set_pattern)) {
            const set = self.typeOf(pattern) orelse return self.unsupported(pattern, "an untyped set pattern");
            const members = try self.facts.errorSetMembers(set, self.arena.allocator());
            if (members.len == 0) return self.w.writeAll("false");
            try self.w.writeAll("(");
            for (members, 0..) |m, i| {
                if (i > 0) try self.w.writeAll(" or ");
                try self.w.print("{s} == error.", .{subj});
                try writeErrorName(self.w, m.facts, m.set, m.name);
            }
            return self.w.writeAll(")");
        }
        // A string compares with the subject's bytes.
        if (pattern == .src and facts.syntax.isStringLiteralText(self.srcText(pattern))) {
            try self.w.print("rig.textIs({s}, ", .{subj});
            try self.emitExpr(pattern);
            return self.w.writeAll(")");
        }
        try self.w.print("{s} == ", .{subj});
        try self.writePatternHead(pattern, info);
    }

    /// Before a guard: the bindings of `pattern` that `guard` names, read
    /// from `subj` (for `match <x`, views of the value still in `x`).
    fn guardBindings(self: *Emitter, pattern: Sexp, guard: Sexp, info: MatchInfo, subj: []const u8) Error!void {
        if (self.isCatchAll(pattern)) {
            const sym = self.facts.symbolOf(pattern) orelse return;
            if (!self.usesSymbol(guard, sym)) return;
            const aliases = try self.wholeBinding(pattern, subj, info, .nil);
            return self.emitPrelude(.{ .aliases = aliases });
        }
        // `g: E if ... =>`: `g` is the subject as an `E`, which the arm's
        // test checked before the guard.
        if (pattern.isKind(.set_pattern)) {
            const name = ir.SetPattern.name(pattern);
            const sym = self.facts.symbolOf(name) orelse return;
            if (!self.usesSymbol(guard, sym)) return;
            if (self.matchesErrorValue(info)) return self.emitPrelude(.{ .aliases = try self.wholeAlias(name, subj, guard) });
            const set = self.typeOf(pattern) orelse return;
            var buf: Writer.Allocating = .init(self.arena.allocator());
            {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                try self.w.writeAll("@as(");
                try self.emitTypeTy(set);
                try self.w.print(", @errorCast({s}))", .{subj});
            }
            return self.emitPrelude(.{ .aliases = try self.wholeAlias(name, buf.written(), guard) });
        }
        if (!pattern.isKind(.variant_pattern)) return;
        const vname = self.srcText(rig.variantPatternName(pattern));
        const err_value = self.matchesErrorValue(info);
        const fields = self.variantPayload(if (err_value) self.typeOf(pattern) orelse info.ty.? else info.ty.?, vname) orelse return self.unsupported(pattern, "this payload pattern");
        // An error's fields are read through its bytes.
        const payload = if (err_value) try self.errorFieldsText(pattern, info, subj) else try self.fmt("{s}.{f}", .{ subj, ident(vname) });
        for (self.facts.payloadBindings(pattern) orelse &.{}, fields) |b, f| {
            const sym = self.facts.symbolOf(b) orelse continue;
            if (!self.usesSymbol(guard, sym)) continue;
            const local = self.payloadLocal(b) orelse continue;
            // A write binds a pointer to each field, and a read one to a
            // field it views (`?F`) or reads in place.
            const addr = try self.need(self.facts.bindsByAddress(b), b);
            const bytes = self.bindsStringBytes(b, local.ty);
            const stored = try self.declare(payloadPointee(local, addr and !bytes), self.srcText(b));
            try self.line("const {s} = {s}{s}.{f}{s};", .{ stored.zig_name, if (addr and !bytes) "&" else "", payload, ident(f.name), if (bytes) ".bytes()" else "" });
        }
    }

    /// The prelude that binds the names of `pattern` that `body` uses,
    /// for the arm picked by a guarded match, from `subj`.
    fn armBindings(self: *Emitter, arm: Sexp, info: MatchInfo, subj: []const u8) Error!Prelude {
        const pattern = ir.Arm.pattern(arm);
        const body = ir.Arm.body(arm);
        if (info.mode == .consume) {
            // The arm takes the value: `x` is consumed now.
            const whole = try self.hiddenStorage(arm, .whole, .owned, .fresh);
            var buf: Writer.Allocating = .init(self.arena.allocator());
            if (info.temp) try buf.writer.writeAll(info.reread) else {
                const saved_w = self.w;
                self.w = &buf.writer;
                defer self.w = saved_w;
                try self.emitBare(info.subject);
            }
            const head = try self.fmt("const {s} = {s};", .{ whole, buf.written() });
            var prelude: Prelude = undefined;
            if (self.isCatchAll(pattern)) {
                const named = !std.mem.eql(u8, self.srcText(pattern), "_");
                prelude = try self.ownedParts(&.{if (named) pattern else .nil}, &.{.{ .expr = whole }}, body);
            } else if (pattern.isKind(.variant_pattern)) {
                const vname = self.srcText(rig.variantPatternName(pattern));
                const fields = self.variantPayload(if (info.error_set) self.typeOf(pattern) orelse info.ty.? else info.ty.?, vname) orelse &.{};
                const payload = if (self.matchesErrorValue(info)) try self.fmt("{s}.*", .{try self.errorFieldsText(pattern, info, whole)}) else try self.fmt("{s}.{f}", .{ whole, ident(vname) });
                prelude = try self.consumedPayload(self.facts.payloadBindings(pattern) orelse &.{}, fields, payload, body);
            } else prelude = try self.ownedParts(&.{.nil}, &.{.{ .expr = whole }}, body);
            prelude.head = head;
            return prelude;
        }
        if (self.isCatchAll(pattern)) {
            if (std.mem.eql(u8, self.srcText(pattern), "_")) return .{};
            return .{ .aliases = try self.wholeBinding(pattern, subj, info, body) };
        }
        // `g: E =>`: `g` is the subject as an `E`, which the arm's test
        // checked it is.
        if (pattern.isKind(.set_pattern)) {
            if (self.matchesErrorValue(info)) return .{ .aliases = try self.wholeAlias(ir.SetPattern.name(pattern), subj, body) };
            const set = self.typeOf(pattern) orelse return .{};
            var buf: Writer.Allocating = .init(self.arena.allocator());
            const saved_w = self.w;
            self.w = &buf.writer;
            defer self.w = saved_w;
            try self.w.writeAll("@as(");
            try self.emitTypeTy(set);
            try self.w.print(", @errorCast({s}))", .{subj});
            return .{ .aliases = try self.wholeAlias(ir.SetPattern.name(pattern), buf.written(), body) };
        }
        if (!pattern.isKind(.variant_pattern)) return .{};
        const vname = self.srcText(rig.variantPatternName(pattern));
        const captures = self.facts.payloadBindings(pattern) orelse return .{};
        if (self.matchesErrorValue(info)) {
            var arm_info = info;
            arm_info.ty = self.typeOf(pattern) orelse info.ty;
            return .{ .aliases = try self.payloadAliases(captures, arm_info, vname, .{ .expr = try self.errorFieldsText(pattern, info, subj) }, body) };
        }
        return .{ .aliases = try self.payloadAliases(captures, info, vname, .{ .expr = try self.fmt("{s}.{f}", .{ subj, ident(vname) }) }, body) };
    }

    /// A payload binding: `const zig_name = payload.field`, or of
    /// `payload` itself when `field` is empty (`&place` for the whole
    /// value of a `match !x`); `addr` takes the field's address, for a
    /// `match !x` binding that writes it.
    /// `addr`: the binding points at the field.
    const Alias = struct { zig_name: []const u8, payload: []const u8, field: []const u8, addr: bool = false, bytes: bool = false };

    /// Whether payload binding `b`, of type `bound`, is the bytes of the
    /// String field it binds (`Facts.viewsStringBytes`).
    fn bindsStringBytes(self: *Emitter, b: Sexp, bound: ?TypeId) bool {
        const field = self.facts.payloadFieldOf(b) orelse return false;
        return self.facts.viewsStringBytes(field, bound orelse return false);
    }

    /// A part of a value a `match <x` arm owns: a field, or the whole
    /// payload or value.
    const OwnedPart = struct { expr: []const u8 };

    /// The prelude of a `match <x` arm: each part named by a binding the
    /// arm uses (in `used_in`, when given; `binds[i]` is `.nil` or `_`
    /// for none) becomes an owned
    /// local, dropped at the end of the arm unless moved; every other
    /// part is dropped at the end of the arm.
    fn ownedParts(self: *Emitter, binds: []const Sexp, parts: []const OwnedPart, used_in: Sexp) Error!Prelude {
        var owned: std.ArrayList(OwnedBinding) = .empty;
        var drops: std.ArrayList([]const u8) = .empty;
        const a = self.arena.allocator();
        for (binds, parts) |b, part| {
            const used = if (b == .src and !std.mem.eql(u8, self.srcText(b), "_")) self.usedPayloadLocal(b, used_in) else null;
            if (used) |l| {
                var local = l;
                if (local.kind != null) local.guard = self.resourceGuard(local.sym);
                const stored = try self.declare(local, self.srcText(b));
                try owned.append(a, .{ .local = stored.*, .expr = part.expr });
            } else try drops.append(a, part.expr);
        }
        return .{ .owned = owned.items, .drops = drops.items };
    }

    /// An owned local a `match <x` arm binds from a part of the value.
    const OwnedBinding = struct { local: Local, expr: []const u8 };

    /// Bindings a branch body starts with: payload field aliases,
    /// or the owning binding of `if expr as name`.
    const Prelude = struct {
        /// A line before the rest: the value a `match <x` arm takes.
        head: []const u8 = "",
        aliases: []const Alias = &.{},
        /// The parts of a consumed value a `match <x` arm binds, and the
        /// parts it drops at its end.
        owned: []const OwnedBinding = &.{},
        drops: []const []const u8 = &.{},
        optional: ?OptionalBinding = null,
        lent: ?OptionalBinding = null,
        /// The error a `catch |err|` handler names, captured as `tmp`.
        err_capture: ?struct { zig_name: []const u8, tmp: []const u8, ty: TypeId, slot: ?[]const u8 = null } = null,
        /// The results `if f() as a, b` captures as `tmp`, which its names
        /// take (`emitResultsHead`).
        results: ?struct { cond: Sexp, tmp: []const u8 } = null,

        fn isEmpty(p: Prelude) bool {
            return p.head.len == 0 and p.aliases.len == 0 and p.owned.len == 0 and p.drops.len == 0 and p.optional == null and p.lent == null and p.err_capture == null and p.results == null;
        }
    };

    /// A resource bound by `as`: captured as `tmp`, then owned by a local
    /// declared at the top of the body (or dropped at once for `as _`).
    /// `copy`: a viewed binding of a copy of the value inside, which the
    /// header captures by value (`Facts.copiesHeader`), held in a local.
    /// `value`: `tmp` holds the optional's payload itself, not a pointer to it.
    const OptionalBinding = struct { cond: Sexp, name: Sexp, tmp: []const u8, copy: bool = false, value: bool = false, held: bool = false };

    /// `payloadLocal` for a binding used in `used_in`, or anywhere when
    /// it is `.nil`.
    fn usedPayloadLocal(self: *Emitter, name_node: Sexp, used_in: Sexp) ?Local {
        const local = self.payloadLocal(name_node) orelse return null;
        if (used_in != .nil and !self.usesSymbol(used_in, local.sym)) return null;
        return local;
    }

    /// A payload binding local, viewing the scrutinee.
    fn payloadLocal(self: *Emitter, name_node: Sexp) ?Local {
        const sym = self.facts.symbolOf(name_node) orelse return null;
        if (!self.usage.used.contains(sym)) return null;
        const ty = self.symType(sym);
        return .{ .sym = sym, .ty = ty, .kind = self.holdOf(sym) };
    }

    /// `|name| ` for a payload or catch-all binding that the body uses:
    /// `|*name| ` for one that views the matched value where it is.
    fn emitCapture(self: *Emitter, name_node: Sexp) Error!void {
        const local = self.payloadLocal(name_node) orelse return;
        const t = local.ty orelse return self.unsupported(name_node, "a catch-all binding of unknown type");
        const by_addr = try self.need(self.facts.catchAllCaptured(name_node), name_node);
        // A value captured by address is held as a pointer to it; a view
        // held as a pointer is that pointer.
        const stored = try self.declare(payloadPointee(local, by_addr and !self.isPtrViewTy(t)), self.srcText(name_node));
        try self.w.print("|{s}{s}| ", .{ if (by_addr) "*" else "", stored.zig_name });
    }

    /// Where payload bindings read their fields: an expression, or a
    /// capture of `arm`'s named here.
    const PayloadAt = union(enum) { expr: []const u8, arm: Sexp };

    /// Bindings for a payload's fields that the arm uses (in `used_in`,
    /// when given), declared in the arm's scope, read from the payload
    /// `at` names. A `match !x` binding (`writes`) points at its field,
    /// unless the field is itself a view, which is bound as it is.
    fn payloadAliases(self: *Emitter, captures: []const Sexp, info: MatchInfo, variant: []const u8, at: PayloadAt, used_in: Sexp) Error![]const Alias {
        const writes = info.mode == .write;
        const fields = self.variantPayload(info.ty.?, variant) orelse return self.unsupported(captures[0], "this payload pattern");
        var out: std.ArrayList(Alias) = .empty;
        var payload: ?[]const u8 = switch (at) {
            .expr => |e| e,
            .arm => null,
        };
        // A capture is by address when a binding views or writes its
        // field, and a copy otherwise.
        var by_addr = writes;
        for (captures) |c| {
            if (self.usedPayloadLocal(c, used_in) == null) continue;
            if (try self.need(self.facts.bindsByAddress(c), c)) by_addr = true;
        }
        for (captures, fields) |c, f| {
            const local = self.usedPayloadLocal(c, used_in) orelse continue;
            const addr = try self.need(self.facts.bindsByAddress(c), c);
            const bytes = self.bindsStringBytes(c, local.ty);
            const stored = try self.declare(payloadPointee(local, addr and !bytes), self.srcText(c));
            if (payload == null) payload = try self.hiddenStorage(at.arm, .payload, if (by_addr) .pointer else .copy, .fresh);
            try out.append(self.arena.allocator(), .{ .zig_name = stored.zig_name, .payload = payload.?, .field = f.name, .addr = addr, .bytes = bytes });
        }
        return out.items;
    }

    /// A payload binding `local` bound by address (`addr`) holds a pointer
    /// to the field, also when its type is the field's own (a type
    /// parameter's value read in place): reading it reads the field.
    fn payloadPointee(local: Local, addr: bool) Local {
        var l = local;
        if (addr) l.is_ptr = true;
        return l;
    }

    fn emitPrelude(self: *Emitter, prelude: Prelude) Error!void {
        if (prelude.head.len > 0) try self.line("{s}", .{prelude.head});
        for (prelude.aliases) |a| {
            if (a.field.len == 0) {
                try self.line("const {s} = {s};", .{ a.zig_name, a.payload });
            } else try self.line("const {s} = {s}{s}.{f}{s};", .{ a.zig_name, if (a.addr and !a.bytes) "&" else "", a.payload, ident(a.field), if (a.bytes) ".bytes()" else "" });
        }
        // Zig writes a deferred call again at each exit: the part goes by
        // address, never by value (`rig.discardAt`).
        for (prelude.drops) |d| try self.line("defer rig.discardAt(&{s});", .{d});
        for (prelude.owned) |o| {
            const is_var = o.local.kind == .value or o.local.kind == .optional;
            try self.line("{s} {s} = {s};", .{ if (is_var) "var" else "const", o.local.zig_name, o.expr });
            if (o.local.guard != .none) {
                try self.writeIndent(self.indent);
                try self.emitGuard(&o.local);
                try self.w.writeAll("\n");
            } else if (is_var) try self.line("_ = &{s};", .{o.local.zig_name});
        }
        if (prelude.optional) |o| try self.bindOptionalResource(o);
        if (prelude.lent) |o| try self.bindOptionalView(o);
        // The callee's set: `anyerror` for a `T!`, the set a `T!E` names.
        if (prelude.err_capture) |c| {
            try self.writeIndent(self.indent);
            try self.w.print("const {s}: ", .{c.zig_name});
            try self.emitTypeTy(c.ty);
            // An error that carries fields is its code and its slot's
            // fields, which the binding now owns.
            if (c.slot) |slot| {
                try self.w.print(" = rig.ErrorValue.taken({s}, &{s});\n", .{ c.tmp, slot });
            } else if (self.isErrorValueTy(c.ty)) {
                try self.w.print(" = rig.ErrorValue.taken({s}, &rig.no_error_data);\n", .{c.tmp});
            } else try self.w.print(" = {s};\n", .{c.tmp});
        }
        if (prelude.results) |r| try self.bindResults(r.cond, r.tmp);
    }

    /// `(f()) |__rig_res_N| ` for `if f() as a, b`: the results are
    /// captured, and the prelude has each name take its own
    /// (`bindResults`).
    fn emitResultsHead(self: *Emitter, cond: Sexp) Error!Prelude {
        try self.w.writeAll("(");
        try self.emitHeader(ir.AsResults.value(cond));
        try self.w.writeAll(") ");
        const tmp = try self.hiddenStorage(cond, .results, .owned, .next);
        try self.w.print("|{s}| ", .{tmp});
        return .{ .results = .{ .cond = cond, .tmp = tmp } };
    }

    /// The names of `if f() as a, b` take their results, captured as
    /// `tmp`, each as the binding `a = e` it is. Every result has a name
    /// (`_` is rejected there), so nothing is dropped here.
    fn bindResults(self: *Emitter, cond: Sexp, tmp: []const u8) Error!void {
        const names = ir.AsResults.names(cond).items();
        const saved = self.part_name;
        defer self.part_name = saved;
        const resumed = try self.enterUnit(cond);
        defer self.leaveUnit(resumed);
        for (names, 0..) |n, j| {
            if (!n.isKind(.set)) return self.unsupported(n, "a result `as` discards");
            self.part_name = try self.fmt("{s}[{d}]", .{ tmp, j });
            try self.writeIndent(self.indent);
            try self.emitSet(n);
            try self.w.writeAll("\n");
        }
    }

    /// `(expr) |capture| ` for `if expr as name` / `while expr as name`.
    /// Plain data is captured under the binding's name; a resource is
    /// captured as a temporary that the returned prelude hands to an
    /// owning local inside the body.
    fn emitOptionalHead(self: *Emitter, cond: Sexp) Error!Prelude {
        const name = ir.As.name(cond);
        const value = ir.As.value(cond);
        const sym = self.facts.symbolOf(name);
        // The header binds a copy of a value with temporaries that reaches
        // no place (`copiesHeader`); a place it reaches, the place's own.
        const owns = value.isKind(.move) or (try self.need(self.facts.handsOver(value), value) == .made and !self.facts.isReadOrWriteView(self.typeOf(value) orelse return self.unsupported(value, "an untyped `as` value")));
        const copies = !owns and try self.copiesSubject(cond, value);
        const points = try self.headerPoints(value);
        // An optional that goes through the helpers is tested as the Zig
        // optional `rig.some` gives, and captured by address through
        // `rig.somePtr`.
        const routed = self.routedOptional(self.typeOf(value));
        // A place, or a part of a value the `if` holds, is bound where it
        // stands, as `if ?o as x` binds it (`Header`).
        if (self.facts.headerOf(cond) != null) {
            try self.w.writeAll(if (routed) "(rig.somePtr(" else "(");
            if (points) {
                try self.emitSubjectPtr(value, false);
                if (!routed) try self.w.writeAll(".*");
            } else {
                if (routed) try self.w.writeAll("&(");
                try self.emitBare(value);
                if (routed) try self.w.writeAll(")");
            }
            try self.w.writeAll(if (routed) ")) " else ") ");
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .pointer, .next);
            try self.w.print("|{s}{s}| ", .{ if (routed) "" else "*", tmp });
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp } };
        }
        // Over a generic view of an optional (`rig.ReadView`), the value
        // inside is read through `rig.viewed` and captured as a copy that
        // owns nothing, as a `for` binds an element it reads.
        if (try self.viewsOptionalValue(value)) if (self.genericReadView(self.typeOf(value) orelse return self.unsupported(value, "an untyped `as` value"))) |viewed| {
            try self.w.writeAll(if (routed) "(rig.some(" else "(");
            const h = try self.openHeader(value);
            try self.writeViewedOpen(viewed);
            try self.emitWriteViewPtr(value);
            try self.w.writeAll(")");
            try self.closeHeader(h);
            try self.w.writeAll(if (routed) ")) " else ") ");
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .copy, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp, .held = true } };
        };
        // Over a view of an optional, a viewed binding points into it.
        if ((try self.viewsOptionalValue(value)) and copies) {
            // A view of a temporary the header drops: the optional is
            // read inside the header, and the binding views a copy of the
            // value inside, which the ownership checker lets nothing use
            // past the header.
            try self.w.writeAll(if (routed) "(rig.some(" else "(");
            const h = try self.openHeader(value);
            try self.w.writeAll("(");
            try self.emitBare(value);
            try self.w.writeAll(").*");
            try self.closeHeader(h);
            try self.w.writeAll(if (routed) ")) " else ") ");
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .copy, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp, .copy = true } };
        }
        if (try self.viewsOptionalValue(value)) {
            // A name holding a view is emitted as the place it points to.
            // `o` and `<o` of a name holding the view are the place.
            const named = value == .src or (value.isKind(.move) and ir.Move.operand(value) == .src);
            if (points) {
                // A place reached through temporaries is viewed where it is.
                try self.w.writeAll(if (routed) "(rig.somePtr(" else "(");
                try self.emitSubjectPtr(value, false);
                try self.w.writeAll(if (routed) ")) " else ".*) ");
            } else if (named) {
                try self.w.writeAll(if (routed) "(rig.somePtr(&(" else "(");
                try self.emitBare(value);
                try self.w.writeAll(if (routed) "))) " else ") ");
            } else {
                // Any other view, a field's or an element's included, is
                // read through the pointer it is, once.
                try self.w.writeAll(if (routed) "(rig.somePtr(" else "((");
                try self.emitWriteViewPtr(value);
                try self.w.writeAll(if (routed) ")) " else ").*) ");
            }
            if (sym == null or !self.usage.used.contains(sym.?)) {
                try self.w.writeAll("|_| ");
                return .{};
            }
            const tmp = try self.hiddenStorage(cond, .as_value, .pointer, .next);
            try self.w.print("|{s}{s}| ", .{ if (routed) "" else "*", tmp });
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp } };
        }
        try self.w.writeAll(if (routed) "(rig.some(" else "(");
        if (points) {
            try self.emitSubjectPtr(value, false);
            try self.w.writeAll(".*");
        } else {
            // An optional built of constants is tested at run time, and
            // so is the value inside it.
            const fixed = self.isScalarPart(value) and isZigComptimeIn(self, value, 0);
            try self.openFixed(fixed, value);
            try self.emitHeader(value);
            try self.closeFixed(fixed, value);
        }
        try self.w.writeAll(if (routed) ")) " else ") ");
        // `as _` binds no symbol; a resource inside is dropped at once.
        const ty: ?TypeId = if (sym) |s| self.symType(s) else if (self.typeOf(value)) |t| switch (self.facts.types.get(self.peelViews(t))) {
            .optional => |inner| inner,
            else => null,
        } else null;
        if (if (self.facts.storageOf(cond, .as_value)) |st| st.by == .owned else false) {
            const tmp = try self.hiddenStorage(cond, .as_value, .owned, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .optional = .{ .cond = cond, .name = if (sym != null) name else .nil, .tmp = tmp } };
        }
        if (sym == null or !self.usage.used.contains(sym.?)) {
            try self.w.writeAll("|_| ");
        } else if (self.facts.optionalBindsStringBytes(cond)) {
            const tmp = try self.hiddenStorage(cond, .as_value, .pointer, .next);
            try self.w.print("|{s}| ", .{tmp});
            return .{ .lent = .{ .cond = cond, .name = name, .tmp = tmp, .value = true } };
        } else {
            // A read binding of a write view to a value read by copy holds
            // the write view, a pointer to that value
            // (`Facts.readsThroughWrite`).
            const through = if (self.optionalInner(value)) |inner| self.facts.readsThroughWrite(sym.?, inner) else null;
            const local = try self.declare(.{ .sym = sym.?, .ty = ty, .is_ptr = through == .value }, self.srcText(name));
            try self.w.print("|{s}| ", .{local.zig_name});
        }
        return .{};
    }

    /// `storage.viewsOptionalValue`.
    fn viewsOptionalValue(self: *Emitter, value: Sexp) Error!bool {
        return self.need(self.facts.viewsOptionalValue(value), value);
    }

    /// A view bound by `as`: `tmp` points at the value inside the
    /// optional, and the binding is declared from it at the top of the body.
    fn bindOptionalView(self: *Emitter, o: OptionalBinding) Error!void {
        const sym = self.facts.symbolOf(o.name).?;
        const ty = self.symType(sym).?;
        const local = try self.declare(.{ .sym = sym, .ty = ty }, self.srcText(o.name));
        // A read binding of a write view inside the optional is the read
        // view of what it views: the write view itself, or the value it
        // points at, copied out (`Facts.readsThroughWrite`).
        const through: ?facts.ThroughWrite = if (self.optionalInner(ir.As.value(o.cond))) |inner| self.facts.readsThroughWrite(sym, inner) else null;
        // A binding of the String inside, or of the String a write view inside
        // points at, is its bytes.
        const inner = self.optionalInner(ir.As.value(o.cond));
        const bytes = if (inner) |i| self.facts.viewsStringBytes(i, ty) else false;
        const through_ptr = bytes and self.facts.types.get(inner.?) == .write_view and !o.value;
        if (o.held) return self.line("const {s} = {s};", .{ local.zig_name, o.tmp });
        if (o.copy) {
            const copy = try self.hiddenStorage(o.cond, .as_copy, .copy, .{ .copy_of = o.tmp });
            try self.line("var {s} = {s};", .{ copy, o.tmp });
            try self.poisonAtExit(copy);
            if (bytes) return self.line("const {s} = {s}{s}.bytes();", .{ local.zig_name, copy, if (through_ptr) ".*" else "" });
            if (through) |t| return self.line("const {s} = {s}{s};", .{ local.zig_name, copy, if (t == .value) ".*" else "" });
            return self.line("const {s} = &{s};", .{ local.zig_name, copy });
        }
        if (bytes) return self.line("const {s} = {s}{s}.bytes();", .{ local.zig_name, o.tmp, if (through_ptr) ".*" else "" });
        if (through) |t| return self.line("const {s} = {s}.*{s};", .{ local.zig_name, o.tmp, if (t == .value) ".*" else "" });
        try self.line("const {s} = {s}{s};", .{ local.zig_name, o.tmp, if (local.is_ptr) "" else ".*" });
    }

    /// The type inside the optional `value` gives, through any views.
    fn optionalInner(self: *Emitter, value: Sexp) ?TypeId {
        const t = self.typeOf(value) orelse return null;
        return switch (self.facts.types.get(self.peelViews(t))) {
            .optional => |inner| inner,
            else => null,
        };
    }

    /// The owning local of a resource bound by `as`, dropped at the end
    /// of the body unless it is moved out.
    fn bindOptionalResource(self: *Emitter, o: OptionalBinding) Error!void {
        if (o.name == .nil) return self.line("rig.discard({s});", .{o.tmp});
        const sym = self.facts.symbolOf(o.name).?;
        const ty = self.symType(sym).?;
        const kind = self.holdOf(sym) orelse return self.unsupported(o.name, "an owned `as` binding that holds nothing");
        const local = try self.declare(.{
            .sym = sym,
            .ty = ty,
            .kind = kind,
            .guard = self.resourceGuard(sym),
        }, self.srcText(o.name));
        const is_var = kind == .value or kind == .optional;
        try self.line("{s} {s} = {s};", .{ if (is_var) "var" else "const", local.zig_name, o.tmp });
        try self.writeIndent(self.indent);
        try self.emitGuard(local);
        try self.w.writeAll("\n");
    }

    // =========================================================================
    // Expressions
    // =========================================================================

    fn emitExpr(self: *Emitter, sexp: Sexp) Error!void {
        return self.emitValue(sexp, false);
    }

    /// An expression in a delimited position: no outer parentheses.
    fn emitBare(self: *Emitter, sexp: Sexp) Error!void {
        self.bare = true;
        return self.emitValue(sexp, false);
    }

    /// Emit an expression. With `tail`, the expression's value leaves
    /// its scope (return, break value): resource bindings in tail
    /// position are moved out.
    fn emitValue(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const entered = try self.enterUnit(sexp);
        defer self.leaveUnit(entered);
        try self.inUnit(sexp);
        // A scalar beside a vector stands for every lane (`sema.splatOf`):
        // Zig splats only where it is told to, and the vector is a run-time
        // value (`writeVectorOpen`).
        if (self.facts.splatOf(sexp)) |vt| if (!sameNode(sexp, self.splatting)) {
            const saved = self.splatting;
            defer self.splatting = saved;
            self.splatting = sexp;
            self.want_ptr = false;
            try self.writeVectorOpen(vt);
            try self.w.writeAll("@splat(");
            try self.emitBare(sexp);
            return self.w.writeAll(")))");
        };
        // A box moved into a box of an API object keeps its allocation,
        // its value's type erased (`sema.Erasure`): `rig.ApiBox(T).of(Square,
        // b, __rig_table_Shape_of(Square, W, .box))`, allocating nothing; a
        // counted handle moved into a `*{A}` keeps its allocation and its
        // count, `rig.ApiShared(T).of(h, __rig_table_Shape_of(Square, W,
        // .counted))`.
        if (!sameNode(sexp, self.erasing_box)) if (self.facts.erasureOf(sexp)) |e| if (e.form == .box or e.form == .shared) {
            const saved = self.erasing_box;
            defer self.erasing_box = saved;
            self.erasing_box = sexp;
            const ty = try self.typeText(e.from);
            try self.emitTypeTy(e.view);
            try self.w.writeAll(if (e.optional) ".ofSome(" else ".of(");
            if (e.form == .box) try self.w.print("{s}, ", .{ty});
            try self.emitValue(sexp, tail);
            try self.w.writeAll(", ");
            try self.writeTableName(e.api);
            try self.w.print("_of({s}, ", .{ty});
            try self.writeWitness(e.witness);
            return self.w.print(", .{s}))", .{@tagName(e.holding)});
        };
        // An error value the function fails with, held rather than made
        // here, sends its fields through the caller's slot.
        if (self.fun.has_out and !sameNode(sexp, self.failing) and self.facts.isFailingLeaf(sexp) and !self.namesErrorMember(sexp) and self.holdsErrorValue(sexp)) {
            const saved = self.failing;
            defer self.failing = saved;
            self.failing = sexp;
            try self.w.print("@errorCast(rig.failValue({s}, ", .{self.fun.out_name});
            try self.emitValue(sexp, tail);
            return self.w.writeAll("))");
        }
        // A `T` or `none` that becomes an optional going through the
        // helpers is packed into it.
        // (A temporary that holds an assignment's new value holds it packed.)
        if (!self.want_ptr and !sameNode(sexp, self.lifting) and !(if (self.hoistedOf(sexp)) |h| h.lifted else false)) if (self.facts.liftOf(sexp)) |lift| if (self.liftRouted(lift)) return self.emitLift(sexp, lift, tail);
        // An error of a set without fields where one that carries fields
        // goes: a `rig.ErrorValue` of its code and none (inside the
        // optional it is lifted into).
        if (!sameNode(sexp, self.widening) and self.facts.isCodeWidening(sexp)) {
            const saved = self.widening;
            defer self.widening = saved;
            self.widening = sexp;
            try self.w.writeAll("rig.ErrorValue.of(");
            try self.emitValue(sexp, tail);
            return self.w.writeAll(", .{})");
        }
        // A part of the value whose use is known has that use; any other
        // value has the use its own context recorded.
        const saved_use = self.use;
        const saved_use_node = self.use_node;
        defer {
            self.use = saved_use;
            self.use_node = saved_use_node;
        }
        if (!try self.partOfUse(sexp)) self.use = self.facts.useOf(sexp);
        self.use_node = sexp;
        const want_ptr = self.want_ptr;
        self.want_ptr = false;
        const bare = self.bare;
        self.bare = false;
        // An owning temporary is kept in its statement's slot, which
        // drops it at the statement's end.
        // A value lent bare is lent around its temporary's slot, as `?e`
        // lends it (unless an argument hoisted before the call holds it).
        if (!sameNode(sexp, self.lending) and self.hoistedOf(sexp) == null) if (self.facts.lendOf(sexp)) |lend| if (lend.implicit) return self.emitLend(sexp, lend, tail, want_ptr);
        // (An argument hoisted before its call was kept there: its name
        // holds the kept value.)
        if (self.facts.dropsTemp(sexp) and !sameNode(sexp, self.keeping) and self.hoistedOf(sexp) == null) {
            const slot = self.tempSlot(sexp) orelse return self.unsupported(sexp, "a temporary outside a statement");
            const saved = self.keeping;
            const saved_ptr = self.ptr_tail;
            defer {
                self.keeping = saved;
                self.ptr_tail = saved_ptr;
            }
            self.keeping = sexp;
            // The slot holds the value: a view of it, the pointer a write
            // lend wants, is taken from the slot (`rig.keep`'s result).
            self.ptr_tail = false;
            try self.w.print("rig.keep(&{s}, &{s}_live, ", .{ slot.name, slot.name });
            self.bare = true;
            try self.emitValue(sexp, tail);
            return self.w.writeAll(").*");
        }
        // A temporary holds the value its context reads (`hoist`).
        if (self.hoistedOf(sexp)) |h| {
            if (h.flag.len > 0) return self.w.print("rig.take(&{s}, {s})", .{ h.flag, h.name });
            return self.w.print("{s}{s}", .{ h.name, if (h.ptr) ".*" else "" });
        }
        if (!sameNode(sexp, self.lending)) if (self.facts.lendOf(sexp)) |lend| {
            if (!lend.has(.read_only)) return self.emitLend(sexp, lend, tail, lend.implicit and want_ptr);
            // A `!{Shape}` lent on to read: the read view it lends.
            if (self.facts.objectView(lend.view) != null) {
                const saved = self.lending;
                defer self.lending = saved;
                self.lending = sexp;
                try self.w.writeAll("(");
                try self.emitValue(sexp, tail);
                return self.w.writeAll(").read()");
            }
        };
        if (!want_ptr and self.readsThrough(sexp)) return self.emitDeref(sexp);
        const literal_ty = self.literal_ty;
        self.literal_ty = null;
        defer self.literal_ty = literal_ty;
        switch (sexp) {
            .src => if (literal_ty != null and isNumberText(self.srcText(sexp))) {
                const text = self.srcText(sexp);
                try self.writeAsOpen(literal_ty.?);
                try self.w.print("{s}{s})", .{ if (text[0] == '.') "0" else "", text });
            } else try self.emitName(sexp, tail),
            .list => try self.emitList(sexp, tail, bare, literal_ty),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// `sexp`, lent where a view of another type is expected, as the rows
    /// of the lend table make it (`SemContext.lendOf`).
    fn emitLend(self: *Emitter, sexp: Sexp, lend: facts.Lend, tail: bool, as_ptr: bool) Error!void {
        const saved = self.lending;
        defer self.lending = saved;
        self.lending = sexp;
        if (lend.callable()) |fn_ty| {
            // A stack closure lent bare is lent as `?f` lends it.
            if (lend.implicit and sexp == .src) if (self.localOf(sexp)) |local| if (local.stack_closure) return self.emitFnRef(sexp, fn_ty);
            return self.emitLentCallable(sexp, fn_ty);
        }
        const rows = lend.steps();
        var first: facts.LendStep = .lift;
        for (rows) |r| if (r != .lift) {
            first = r;
            break;
        };
        // What the lend starts from: the value written `?x` or `!x` here,
        // the bare value lent as `?x` would be, or the view `sexp` already
        // is, which is a pointer to its value or (a scalar's or a view's)
        // a copy of it.
        const written = sexp.isKind(.read) or sexp.isKind(.write);
        if (lend.implicit and rows.len == 0) {
            // `?x` where a `?T` is expected: the address of `x`, or a copy
            // of a scalar or a view.
            if (!self.isPtrViewTy(lend.view)) {
                self.bare = true;
                return self.emitValue(sexp, false);
            }
            return self.emitReadLend(sexp, self.genericReadView(lend.view) != null);
        }
        var buf: Writer.Allocating = .init(self.arena.allocator());
        var at: LendAt = .{ .text = "", .ptr = true };
        var from: TypeId = facts.type_invalid;
        {
            const saved_w = self.w;
            self.w = &buf.writer;
            defer self.w = saved_w;
            if (first == .erase and !(written or lend.implicit)) {
                // A view `sexp` holds, erased as it is: the pointer it
                // holds, or the value a view held as a copy is.
                at.ptr = self.isPtrViewExpr(sexp);
                if (at.ptr) try self.emitWriteViewPtr(sexp) else {
                    self.bare = true;
                    try self.emitValue(sexp, false);
                }
                from = self.facts.unwrapViews(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped lend"));
            } else if (!(written or lend.implicit) or (written and first == .unbox and !lend.has(.text))) {
                try self.w.writeAll("(");
                self.bare = true;
                try self.emitValue(sexp, tail and !written);
                try self.w.writeAll(")");
                at.ptr = written or self.isPtrViewExpr(sexp);
                from = self.facts.unwrapViews(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped lend"));
            } else {
                const operand = if (written) ir.get(sexp, .operand) else sexp;
                from = self.facts.unwrapViews(self.typeOf(operand) orelse return self.unsupported(sexp, "an untyped lend"));
                const list = self.facts.types.get(from) == .parameterized_nominal;
                if (lend.has(.text)) {
                    try self.emitExpr(operand);
                    at.ptr = false;
                } else if (first == .handle or first == .optional or (first == .elems and list)) {
                    try self.emitMemberBase(operand, self.typeOf(operand));
                    at.ptr = false;
                } else if (first == .code) {
                    // A code: its value, whose error value `rig.codeView`
                    // reaches.
                    self.bare = true;
                    try self.emitValue(operand, false);
                    at.ptr = false;
                } else if (first == .erase and operand == .src and isNumberText(self.srcText(operand))) {
                    // A number lent where it is written, held by Zig, typed.
                    const e = self.facts.erasureOf(sexp) orelse return self.unsupported(sexp, "an API object no check recorded");
                    try self.w.print("&@as({s}, {s})", .{ try self.typeText(e.from), self.srcText(operand) });
                } else {
                    const saved_read = self.read_place;
                    defer self.read_place = saved_read;
                    self.read_place = !sexp.isKind(.write);
                    const unbox = first == .unbox;
                    if (unbox) try self.w.writeAll("(");
                    try self.emitAddressOf(operand);
                    if (unbox) try self.w.writeAll(")");
                }
            }
        }
        at.text = buf.written();
        return self.w.writeAll(try self.lendChain(sexp, at, from, rows, lend.view, as_ptr));
    }

    /// A value a lend reaches, as Zig text: a pointer to it (`ptr`), or
    /// the value itself, whose fields and methods Zig reaches the same.
    const LendAt = struct { text: []const u8, ptr: bool };

    /// The API object the value `at`, of type `from`, is erased to
    /// (`sema.Erasure`): its address, or that of the copy it views, and
    /// its type's table, `rig.ApiView(__rig_table_Shape){ .ptr = &sq, .vt
    /// = __rig_table_Shape_of(Square, __rig_impl_Shape_Square) }`.
    fn erasedObject(self: *Emitter, node: Sexp, at: LendAt, from: TypeId) Error![]const u8 {
        const e = self.facts.erasureOf(node) orelse return self.unsupported(node, "an API object no check recorded");
        _ = from;
        const ty = try self.typeText(e.from);
        var ptr = if (at.ptr) at.text else try self.fmt("&{s}", .{at.text});
        if (e.copy) {
            const slot = self.erasedSlot(node) orelse return self.unsupported(node, "an API object's copy without its slot");
            // The value the view held views: a generic read view's, read
            // as `rig.ReadView` holds it.
            const value = if (self.facts.types.get(e.from) == .type_var)
                try self.fmt("rig.viewed({s}, {s})", .{ ty, at.text })
            else if (at.ptr) try self.fmt("{s}.*", .{at.text}) else at.text;
            ptr = try self.fmt("rig.erasedCopy({s}, &{s}, {s})", .{ ty, slot, value });
        }
        var buf: Writer.Allocating = .init(self.arena.allocator());
        const saved = self.w;
        self.w = &buf.writer;
        defer self.w = saved;
        try self.emitTypeTy(e.view);
        try self.w.print("{{ .ptr = {s}, .vt = ", .{ptr});
        try self.writeTableName(e.api);
        try self.w.print("_of({s}, ", .{ty});
        try self.writeWitness(e.witness);
        try self.w.writeAll(", .box) }");
        return buf.written();
    }

    /// The Zig type `ty` is, as text.
    fn typeText(self: *Emitter, ty: TypeId) Error![]const u8 {
        var buf: Writer.Allocating = .init(self.arena.allocator());
        const saved = self.w;
        self.w = &buf.writer;
        defer self.w = saved;
        try self.emitTypeTy(ty);
        return buf.written();
    }

    /// The view the lend table's `rows` make of the value `at`, of type
    /// `from`, where a `view` is expected (`emitLend`), for the lend
    /// `node`.
    fn lendChain(self: *Emitter, node: Sexp, start: LendAt, start_from: TypeId, rows: []const facts.LendStep, start_view: TypeId, as_ptr: bool) Error![]const u8 {
        const types = self.facts.types;
        var at = start;
        var from = start_from;
        var view = start_view;
        for (rows, 0..) |row, i| switch (row) {
            .lift => view = types.get(view).optional,
            .unbox => {
                // A box of an API object lends the view of it the table
                // reaches, `b.read()` or `b.write()`.
                if (self.facts.objectBox(from) != null) return self.fmt("{s}.{s}()", .{ at.text, if (types.get(view) == .write_view) "write" else "read" });
                at = .{ .text = try self.fmt("{s}.value", .{at.text}), .ptr = true };
                from = self.facts.boxedType(from).?;
            },
            // A handle is a pointer: reached through a pointer to it, it is
            // dereferenced first.
            .handle => {
                // A counted API object lends the view it holds, the same
                // two words, `s.read()`.
                if (self.facts.objectHandle(from) != null) return self.fmt("{s}.read()", .{at.text});
                const handle = if (at.ptr) try self.fmt("({s}).*", .{at.text}) else at.text;
                at = .{ .text = try self.fmt("{s}.value", .{handle}), .ptr = false };
                from = types.get(from).shared;
            },
            // An array's address is a slice; a List's elements are its items.
            .elems => return if (types.get(from) == .array)
                (if (at.ptr) at.text else try self.fmt("&{s}", .{at.text}))
            else
                self.fmt("{s}.items()", .{at.text}),
            .text => return self.fmt("{s}.bytes()", .{at.text}),
            .read_only => return at.text,
            // The view of the value inside, or `none`.
            .optional => {
                const name = try self.hiddenStorage(node, .lent, .pointer, .next);
                const inner = try self.lendChain(node, .{ .text = name, .ptr = true }, types.get(from).optional, rows[i + 1 ..], types.get(view).optional, false);
                if (self.routesPayload(types.get(from).optional)) {
                    const ptr = if (at.ptr) at.text else try self.fmt("&({s})", .{at.text});
                    return self.fmt("(if (rig.somePtr({s})) |{s}| {s} else null)", .{ ptr, name, inner });
                }
                const value = if (at.ptr) try self.fmt("({s}).*", .{at.text}) else at.text;
                return self.fmt("(if ({s}) |*{s}| {s} else null)", .{ value, name, inner });
            },
            .callable => unreachable,
            .erase => return self.erasedObject(node, at, from),
            // A code's error value, a constant of the program.
            .code => at = .{ .text = try self.fmt("rig.codeView({s})", .{if (at.ptr) try self.fmt("({s}).*", .{at.text}) else at.text}), .ptr = true },
        };
        const ptr = if (at.ptr) at.text else try self.fmt("&{s}", .{at.text});
        return switch (types.get(view)) {
            .read_view => if (as_ptr) ptr else self.fmt("rig.lend({s})", .{ptr}),
            else => ptr,
        };
    }

    fn emitName(self: *Emitter, sexp: Sexp, tail: bool) Error!void {
        const name = self.srcText(sexp);
        if (self.localOf(sexp)) |local| {
            if (self.rt_names and !self.keep_comptime and self.facts.symbols.items[local.sym].flags.comptime_known) {
                return self.w.print("rig.rt({s})", .{local.zig_name});
            }
            if (tail and self.ptr_tail and local.is_ptr) return self.w.writeAll(local.zig_name);
            if (self.subjectView(sexp, local)) |inner| return self.writeSubjectView(inner, local.zig_name);
            return if (tail and try self.takesTail(sexp, local)) self.writeTake(local) else self.writeLocalPlace(local);
        }
        if (std.mem.eql(u8, name, "none")) {
            if (self_check) if (self.typeOf(sexp)) |t| if (self.isEnumTy(t)) return self.unsupported(sexp, "`none` with an enum type");
            return self.w.writeAll("null");
        }
        if (name[0] == '\'') return writeSingleQuoted(self.w, name);
        if (facts.syntax.isFloatLiteralText(name)) {
            // Typed, so arithmetic on literals rounds like run-time Float math.
            try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.float_id);
            return self.w.print("{s}{s})", .{ if (name[0] == '.') "0" else "", name });
        }
        if (isLiteralText(name)) return self.w.writeAll(name);
        // A built-in type named in an expression: `Endian.big`.
        if (self.facts.symbolOf(sexp)) |id| if (self.facts.isBuiltinEnum(id)) return self.writeNominalName(id);
        if (self.facts.symbolOf(sexp)) |id| if (self.facts.moduleOf(id)) |module| return self.writeModuleZig(module);
        if (self.rt_names and !self.keep_comptime and self.isModuleConst(sexp)) {
            try self.w.writeAll("rig.rt(");
            try self.writeModuleName(name);
            return self.w.writeAll(")");
        }
        try self.writeModuleName(name);
    }

    /// A module constant, or a generic type's value parameter: a
    /// compile-time name without a local.
    fn isModuleConst(self: *Emitter, sexp: Sexp) bool {
        const id = self.facts.symbolOf(sexp) orelse return false;
        const sym = self.facts.symbols.items[id];
        return (sym.kind == .local or sym.kind == .param) and sym.flags.comptime_known;
    }

    /// A module-level name. Inside a type with a method of the same name,
    /// Zig would find both, so it is qualified with the module itself.
    fn writeModuleName(self: *Emitter, name: []const u8) Error!void {
        if (self.nominal) |n| for (n.members) |m| {
            if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
            if (!std.mem.eql(u8, self.srcText(ir.get(m, .name)), name)) continue;
            self.uses_module = true;
            try self.w.writeAll("__rig_module.");
            break;
        };
        try self.w.print("{f}", .{ident(name)});
    }

    /// Whether `sexp`, the value being emitted, is the value whose use is
    /// known or a part of it (`facts.syntax.valueParts`), directly or as the
    /// block whose tail the part is.
    fn partOfUse(self: *Emitter, sexp: Sexp) Error!bool {
        if (self.use_node == .nil) return false;
        if (sameNode(sexp, self.use_node)) return true;
        if (self.use_node.isKind(.match)) {
            const parts = try self.matchParts(self.use_node);
            const tail = facts.syntax.tailOf(sexp);
            return (if (partKey(sexp)) |k| parts.contains(k) else false) or
                (if (partKey(tail)) |k| parts.contains(k) else false);
        }
        var parts = facts.syntax.valueParts(self.use_node);
        while (parts.next()) |p| if (sameNode(p.node, sexp) or sameNode(p.node, facts.syntax.tailOf(sexp))) return true;
        return false;
    }

    /// The value parts of `match` (`facts.syntax.valueParts`), one per
    /// arm, as a set.
    fn matchParts(self: *Emitter, match: Sexp) Error!*const std.AutoHashMapUnmanaged(PartKey, void) {
        const a = self.arena.allocator();
        const entry = try self.match_parts.getOrPut(a, partKey(match).?);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            var parts = facts.syntax.valueParts(match);
            while (parts.next()) |p| if (partKey(p.node)) |k| try entry.value_ptr.put(a, k, {});
        }
        return entry.value_ptr;
    }

    /// Whether name `sexp`, at a tail of the value being emitted, moves
    /// out of `local`: only where the value's context takes it
    /// (`facts.Use`), never where it is read in place. A binding no drop
    /// flag guards has nothing to disarm. A value whose context recorded
    /// no use is an internal error in every build: neither a move nor a
    /// read is right without one.
    fn takesTail(self: *Emitter, sexp: Sexp, local: *const Local) Error!bool {
        if (consumeFlag(local) == null) return false;
        if (self.facts.readsInPlace(sexp)) return false;
        const use = self.use orelse return self.unsupported(sexp, "a value whose use no context recorded");
        return use == .take;
    }

    /// `local`'s value moving out: `rig.take(&flag, x)`, which yields `x`
    /// and disarms a scope-exit drop (`consumeFlag`), or `x` when no drop
    /// is armed.
    fn writeTake(self: *Emitter, local: *const Local) Error!void {
        const flag = consumeFlag(local) orelse return self.writeLocalPlace(local);
        try self.w.print("rig.take(&{s}, ", .{flag});
        try self.writeLocalPlace(local);
        try self.w.writeAll(")");
    }

    /// A value stored into a field, payload, or element: a write view is
    /// stored as its pointer.
    fn emitStored(self: *Emitter, e: Sexp) Error!void {
        if (self.isPtrViewExpr(e) and !self.facts.readsThrough(e)) return self.emitWriteViewPtr(e);
        try self.emitBare(e);
    }

    /// Whether every name in `e` is a constant binding, so folding it
    /// drops no reference Zig would miss (a branch a constant condition
    /// skips may name other locals).
    fn onlyConstantLeaves(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => {
                const sym = self.facts.symbolOf(e) orelse return true;
                return self.facts.isConstInt(sym);
            },
            .list => {
                // A compile-time call's value is a constant.
                if (self.facts.ctValueOf(e) != null) return true;
                for (e.items()) |c| if (!self.onlyConstantLeaves(c)) return false;
                return true;
            },
            else => return true,
        }
    }

    /// Every leaf of `e` is a literal.
    fn literalLeaves(self: *Emitter, e: Sexp) bool {
        switch (e) {
            .src => return self.facts.symbolOf(e) == null,
            .list => {
                for (e.items()) |c| if (!self.literalLeaves(c)) return false;
                return true;
            },
            else => return true,
        }
    }

    fn emitIntConstant(self: *Emitter, sexp: Sexp, v: Wide) Error!void {
        const t = self.typeOf(sexp);
        const concrete = t != null and self.facts.types.get(t.?) == .int;
        if (concrete) {
            try self.writeAsOpen(t.?);
            return self.w.print("{d})", .{v});
        }
        if (v < 0) return self.w.print("({d})", .{v});
        try self.w.print("{d}", .{v});
    }

    /// The number type an expression yields, with literal types at their
    /// defaults; null for anything else.
    fn numericValueTy(self: *Emitter, e: Sexp) ?TypeId {
        const t = self.typeOf(e) orelse return null;
        return switch (self.facts.types.get(t)) {
            .int, .float => t,
            .int_literal => self.facts.types.int_id,
            .float_literal => self.facts.types.float_id,
            else => null,
        };
    }

    fn hasPayloadVariants(self: *Emitter, ty: TypeId) bool {
        const decl = self.facts.nominalDecl(ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| {
            if (f.is_variant and f.payload != null and f.payload.?.len > 0) return true;
        }
        return false;
    }

    fn isEnumTy(self: *Emitter, ty: TypeId) bool {
        const decl = self.facts.nominalDecl(ty) orelse return false;
        for (decl.symbol().fields orelse return false) |f| if (f.is_variant) return true;
        return false;
    }

    /// An expression yielding a pointer view where its context reads the
    /// value behind it (`SemContext.readsThrough`): `!x`, or a call
    /// returning `!Int`. A name, field, or element holding a view reads
    /// through it already.
    fn readsThrough(self: *Emitter, e: Sexp) bool {
        if (e == .src or e.isKind(.member) or e.isKind(.index)) return false;
        return self.facts.readsThrough(e) and self.isPtrViewExpr(e);
    }

    /// An expression whose value is a writable slice `![]T`.
    fn isWriteSliceExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.facts.writeSliceElem(t) != null;
    }

    /// An expression whose value is a pointer view (see `isPtrViewTy`).
    fn isPtrViewExpr(self: *Emitter, e: Sexp) bool {
        const t = self.typeOf(e) orelse return false;
        return self.isPtrViewTy(t);
    }

    /// A view held as a pointer: a write view, and a read view of a
    /// value that owns resources or holds a `Cell` (see `readViewIsPtr`).
    /// A `![]T` is a Zig slice, which points at its elements itself.
    fn isPtrViewTy(self: *Emitter, ty: TypeId) bool {
        return self.facts.viewHeldAsPointer(ty);
    }

    /// A read view of a scalar or a view is a copy
    /// (`sema.lendByValue`); anything else is lent by address.
    fn readViewIsPtr(self: *Emitter, inner: TypeId) bool {
        return !self.facts.lendByValue(inner);
    }

    /// The `T` of a read view `?T` whose form depends on a generic
    /// type's arguments: `T` holds a type parameter and neither owns
    /// resources nor holds a Cell on its own. It is emitted as
    /// `rig.ReadView(T)`, which applies `readViewIsPtr`'s rule to each
    /// instance, so an instance agrees with the code that uses it
    /// (`?Wrap[Int]` is a copy). Code that depends on the form goes through
    /// `rig.lend` and `rig.viewed`; the rest treats it as a pointer, since
    /// Zig reaches fields and methods through either.
    fn genericReadView(self: *Emitter, ty: TypeId) ?TypeId {
        return self.facts.genericReadView(ty);
    }

    fn genericReadViewOf(self: *Emitter, e: Sexp) ?TypeId {
        return self.genericReadView(self.typeOf(e) orelse return null);
    }

    /// `?x` or `!x` held by pointer: the address of `x`, or for a generic
    /// read view, `rig.lend` of it.
    fn emitLendAddress(self: *Emitter, e: Sexp) Error!void {
        if (!sameNode(e, self.lending)) if (self.facts.lendOf(e)) |lend| if (!lend.has(.read_only) and lend.callable() == null) return self.emitLend(e, lend, false, true);
        const operand = ir.get(e, .operand);
        // A read view reaches a List element through a read-only slot, a
        // write view through a writable one.
        const saved_read = self.read_place;
        defer self.read_place = saved_read;
        self.read_place = e.isKind(.read);
        const lends_on = if (self.typeOf(operand)) |t| self.facts.types.get(t) == .read_view else false;
        if (lends_on or !e.isKind(.read)) return self.emitAddressOf(operand);
        return self.emitReadLend(operand, self.genericReadViewOf(e) != null);
    }

    /// A read lend of `operand` as a view held by address: its address,
    /// or for a generic read view (`generic`), `rig.lend` of it, which
    /// gives each instance the view its type is lent as. A lend written
    /// `?x` and one made where a view is expected are written alike.
    fn emitReadLend(self: *Emitter, operand: Sexp, generic: bool) Error!void {
        const saved_read = self.read_place;
        defer self.read_place = saved_read;
        self.read_place = true;
        if (generic) try self.w.writeAll("rig.lend(");
        try self.emitAddressOf(operand);
        if (generic) try self.w.writeAll(")");
    }

    /// `rig.viewed(T, `: the value a generic read view reaches; the
    /// caller writes the view and the `)`.
    fn writeViewedOpen(self: *Emitter, inner: TypeId) Error!void {
        try self.w.writeAll("rig.viewed(");
        try self.emitTypeTy(inner);
        try self.w.writeAll(", ");
    }

    /// `e` yielded where a value of `ty` goes: a view yielded where a
    /// view or an optional view goes stays a view.
    fn emitValueAs(self: *Emitter, e: Sexp, ty: ?TypeId) Error!void {
        if (ty) |t| if (self.isPtrViewExpr(e) and self.isPtrViewTy(self.unwrapOptionals(t))) return self.emitWriteViewPtr(e);
        // A branch's `none` has the optional type of the value: Zig would
        // otherwise give `null` a type of its own, which a branch beside
        // it, or a reference to the branch's value, does not share. A
        // nested `if` of `none`s alone is that type too.
        if (ty) |t| if (self.facts.types.get(t) == .optional) {
            if (self.isNoneLeaf(e)) {
                if (self.routesPayload(self.facts.types.get(t).optional)) {
                    try self.w.writeAll("rig.pack(");
                    try self.emitTypeTy(t);
                    return self.w.writeAll(", null)");
                }
                try self.writeAsOpen(t);
                return self.w.writeAll("null)");
            }
            if (e.isKind(.@"if") and self.typeOf(e) == self.facts.types.none_id) return self.emitIfYieldAs(e, .value, t);
        };
        // A branch's `?String` is a slice, so a literal in one branch and a
        // slice in another have one Zig type.
        if (ty) |t| if (self.unwrapOptional(t) == self.facts.types.string_view_id or self.unwrapOptional(t) == self.facts.types.static_id) {
            try self.w.writeAll("@as(");
            try self.emitTypeTy(t);
            try self.w.writeAll(", ");
            self.bare = true;
            try self.emitValue(e, true);
            return self.w.writeAll(")");
        };
        try self.emitValue(e, true);
    }

    /// `e` where a value of type `target` goes: a view held by pointer
    /// lifted into an optional of that view is the pointer itself, never
    /// the value it reaches.
    fn emitBareAs(self: *Emitter, e: Sexp, target: ?TypeId) Error!void {
        if (target) |t| if (self.facts.types.get(t) == .optional and self.isPtrViewExpr(e) and self.isPtrViewTy(self.unwrapOptionals(t))) return self.emitWriteViewPtr(e);
        try self.emitBare(e);
    }

    // ---- optionals ------------------------------------------------------------
    //
    // A `T?` whose payload is routed (`Facts.optionalRouted`) is written
    // `rig.Opt(T)`, and each operation on it goes through the runtime's
    // helpers: `rig.some(x)` gives Zig's `?T` for a test, `??`, `?`, or
    // `as`; `rig.somePtr(&x)` the payload's address for a `|*v|` capture;
    // and `rig.pack(O, z)` makes the `O` a Zig `?T` stands for, where a `T`
    // or `none` becomes one (`emitLift`). Every other optional is Zig's
    // `?T`, which each form uses directly.

    /// Whether a `T?` of payload `inner` goes through the helpers.
    fn routesPayload(self: *Emitter, inner: TypeId) bool {
        return self.facts.optionalRouted(inner, self.strict_optionals);
    }

    /// Whether `ty`, through any views, is an optional whose payload goes
    /// through the helpers.
    fn routedOptional(self: *Emitter, ty: ?TypeId) bool {
        const t = ty orelse return false;
        return switch (self.facts.types.get(self.peelViews(t))) {
            .optional => |inner| self.routesPayload(inner),
            else => false,
        };
    }

    /// `rig.some(` when `e`'s optional goes through the helpers; the
    /// caller writes `e` and `closeSome`.
    fn openSome(self: *Emitter, e: Sexp) Error!bool {
        if (!self.routedOptional(self.typeOf(e))) return false;
        try self.w.writeAll("rig.some(");
        return true;
    }

    fn closeSome(self: *Emitter, open: bool) Error!void {
        if (open) try self.w.writeAll(")");
    }

    /// Whether some level of the optional `lift` makes goes through the
    /// helpers (`emitLift`).
    fn liftRouted(self: *Emitter, lift: facts.Lift) bool {
        var o = lift.into;
        var levels = self.liftLevels(lift);
        while (levels > 0) : (levels -= 1) {
            const inner = self.facts.types.get(o).optional;
            if (self.routesPayload(inner)) return true;
            o = inner;
        }
        return false;
    }

    /// How many levels of optional `lift` adds to its value: one for
    /// `none`.
    fn liftLevels(self: *Emitter, lift: facts.Lift) u32 {
        if (lift.from == self.facts.types.none_id) return 1;
        return optionalDepth(self.facts.types, lift.into) -| optionalDepth(self.facts.types, lift.from);
    }

    /// `e`, whose value becomes the optional `lift.into` where it goes,
    /// packed level by level into each optional that goes through the
    /// helpers (`rig.pack(O, e)`, and `rig.pack(O, null)` for `none`);
    /// Zig lifts it into any other.
    fn emitLift(self: *Emitter, e: Sexp, lift: facts.Lift, tail: bool) Error!void {
        const saved = self.lifting;
        defer self.lifting = saved;
        self.lifting = e;
        const opened = try self.openPacks(lift.into, self.liftLevels(lift));
        self.bare = true;
        try self.emitValue(e, tail);
        for (0..opened) |_| try self.w.writeAll(")");
    }

    /// `rig.pack(O, ` for each of the outer `levels` levels of the optional
    /// `into` that goes through the helpers; returns how many the caller
    /// closes.
    fn openPacks(self: *Emitter, into: TypeId, levels: u32) Error!u32 {
        var o = into;
        var opened: u32 = 0;
        for (0..levels) |_| {
            const inner = switch (self.facts.types.get(o)) {
                .optional => |inner| inner,
                else => break,
            };
            if (self.routesPayload(inner)) {
                try self.w.writeAll("rig.pack(");
                try self.emitTypeTy(o);
                try self.w.writeAll(", ");
                opened += 1;
            }
            o = inner;
        }
        return opened;
    }

    /// The type `ty` holds under every level of optional; any other type
    /// itself.
    fn unwrapOptionals(self: *Emitter, ty: TypeId) TypeId {
        var inner = ty;
        while (self.facts.types.get(inner) == .optional) inner = self.facts.types.get(inner).optional;
        return inner;
    }

    /// The type a fallible `ty` succeeds with; any other type itself.
    fn unwrapFallible(self: *Emitter, ty: TypeId) TypeId {
        return switch (self.facts.types.get(ty)) {
            .fallible => |inner| inner.ok,
            else => ty,
        };
    }

    /// The type an optional `ty` holds; any other type itself.
    fn unwrapOptional(self: *Emitter, ty: TypeId) TypeId {
        return switch (self.facts.types.get(ty)) {
            .optional => |inner| inner,
            else => ty,
        };
    }

    /// `(e).*`: the value a pointer view reaches.
    fn emitDeref(self: *Emitter, e: Sexp) Error!void {
        if (self.genericReadViewOf(e)) |inner| {
            try self.writeViewedOpen(inner);
            try self.emitWriteViewPtr(e);
            return self.w.writeAll(")");
        }
        try self.w.writeAll("(");
        try self.emitWriteViewPtr(e);
        try self.w.writeAll(").*");
    }

    /// The value a pointer view `e` reaches, switched on where it is. A
    /// generic read view a name holds is reached through the name's
    /// address (`rig.viewedPtr`), so a payload captured by pointer is
    /// the one the view reaches, or the name's own copy, never a copy
    /// in a Zig temporary.
    fn emitSwitchDeref(self: *Emitter, e: Sexp) Error!void {
        if (self.switchesThroughName(e)) {
            const inner = self.genericReadViewOf(e).?;
            try self.w.writeAll("rig.viewedPtr(");
            try self.emitTypeTy(inner);
            try self.w.writeAll(", &");
            try self.emitWriteViewPtr(e);
            return self.w.writeAll(").*");
        }
        try self.emitDeref(e);
    }

    /// Whether `e` is a name holding a generic read view (`?T`, `?Self`).
    fn switchesThroughName(self: *Emitter, e: Sexp) bool {
        return e == .src and self.localOf(e) != null and self.genericReadViewOf(e) != null;
    }

    /// A write view: the pointer a `!T` expression denotes.
    fn emitWriteViewPtr(self: *Emitter, e: Sexp) Error!void {
        const saved = self.ptr_tail;
        defer self.ptr_tail = saved;
        self.ptr_tail = true;
        self.bare = true;
        self.want_ptr = true;
        try self.emitValue(e, true);
    }

    /// `@as(T, `: the caller writes the value and the `)`.
    fn writeAsOpen(self: *Emitter, ty: TypeId) Error!void {
        try self.w.writeAll("@as(");
        try self.emitTypeTy(ty);
        try self.w.writeAll(", ");
    }

    /// `@intCast(` of `value`, of type `from`, to an unsigned integer
    /// type `to_bits` wide (null when Zig infers it, a shift amount's or
    /// an enum's backing type), closed by `closeUnsignedCast` with what it
    /// returns. A signed value narrowed is cast to the unsigned type of
    /// its own width first: Zig lowers a cast from a signed type to a
    /// narrower unsigned one as LLVM `trunc nsw`, a promise that the value
    /// fits the narrower *signed* type, so in a release build any value at
    /// or above the target's sign bit would be poison (`U8(200) >= 128`
    /// false). From the unsigned type the narrowing is `trunc nuw`, and a
    /// negative value still fails the first cast. A constant is cast when
    /// Zig compiles.
    fn openUnsignedCast(self: *Emitter, value: Sexp, from: ?TypeId, to_bits: ?u8) Error!bool {
        try self.w.writeAll("@intCast(");
        const ty = from orelse return false;
        const info = switch (self.facts.types.get(self.peelViews(ty))) {
            .int => |i| i,
            else => return false,
        };
        if (!info.signed or self.literalLeaves(value)) return false;
        if (to_bits) |bits| if (bits >= info.width()) return false;
        try self.w.print("@as(u{d}, @intCast(", .{info.width()});
        return true;
    }

    fn closeUnsignedCast(self: *Emitter, through: bool) Error!void {
        try self.w.writeAll(if (through) ")))" else ")");
    }

    /// The pointer a view of `inner` held by address is: a write view's
    /// is mutable, `*T`; a read view's is `*const T`.
    fn emitViewPtrTy(self: *Emitter, inner: TypeId, view: enum { read, write }) Error!void {
        try self.w.writeAll(if (view == .write) "*" else "*const ");
        try self.emitTypeTy(inner);
    }

    /// `*T` / `*const T` for a view type.
    fn emitPointerTy(self: *Emitter, ty: TypeId) Error!void {
        if (self.genericReadView(ty) != null) return self.emitTypeTy(ty);
        switch (self.facts.types.get(ty)) {
            .read_view, .write_view => |inner| try self.emitViewPtrTy(inner, if (self.facts.types.get(ty) == .read_view) .read else .write),
            else => try self.emitTypeTy(ty),
        }
    }

    /// `<x`: the value leaves its binding.
    fn emitMoved(self: *Emitter, inner: Sexp) Error!void {
        if (inner == .src) if (self.localOf(inner)) |local| {
            if (consumeFlag(local) != null) return self.writeTake(local);
        };
        // A field moved out of a local clears the flag its drop waits on.
        if (try self.partsOf(inner)) |at| for (at.local.parts, at.local.part_flags) |p, f| {
            if (!std.mem.eql(u8, p, at.path)) continue;
            try self.w.print("rig.take(&{s}, ", .{f});
            try self.emitBare(inner);
            return self.w.writeAll(")");
        };
        try self.emitBare(inner);
    }

    fn emitList(self: *Emitter, sexp: Sexp, tail: bool, bare: bool, literal_ty: ?TypeId) Error!void {
        const head = sexp.kind().?;
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        switch (head) {
            // Literal operands of float or type-parameter arithmetic take
            // its type.
            .@"+", .@"-", .@"*", .@"/", .@"%", .neg => if (literal_ty orelse self.literalTypeOf(sexp)) |f| {
                self.literal_ty = f;
            },
            else => {},
        }
        if (self.literal_ty == null) switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^", .neg, .@"if" => {
                // Sema computed a constant integer expression (and checked
                // that it fits); its value is written as a literal, so Zig
                // does not evaluate it again with other intermediate types.
                if (self.facts.constIntOf(sexp)) |v| if (self.onlyConstantLeaves(sexp)) return self.emitIntConstant(sexp, v);
            },
            else => {},
        };
        switch (head) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .neg, .index => self.rt_names = true,
            else => {},
        }
        switch (head) {
            // A destructure's target takes its result out of the
            // statement's results (`emitDestructure`).
            .result_part => try self.w.writeAll(self.part_name),
            // `?a` / `!a` of an array lent as a slice: the array's address,
            // which Zig takes as a slice.
            .read, .write => if (head == .read) {
                // `?f` of a closure or function lends it.
                if (self.typeOf(sexp)) |t| if (self.facts.callableFn(t) != null) return self.emitFnRef(ir.Read.operand(sexp), self.facts.callableFnTy(t).?);
                // `?x` of a value held by pointer (a Cell) is its address.
                if (self.isPtrViewExpr(sexp)) return self.emitLendAddress(sexp);
                // A view never moves its operand, even in tail position.
                self.bare = bare;
                try self.emitValue(ir.Read.operand(sexp), false);
            } else if (self.isWriteSliceExpr(sexp))
                // `!x` as a value (an argument, a receiver) is the place's
                // address; a `![]T` is the slice.
                try self.emitExpr(ir.Write.operand(sexp))
            else
                try self.emitAddressOf(ir.Write.operand(sexp)),
            .move => {
                const operand = ir.Move.operand(sexp);
                // `<p.f` of an optional takes it, leaving `none`; the
                // place's own parts keep their parentheses.
                if (self.facts.takes(sexp)) {
                    try self.w.writeAll("rig.takeOut(");
                    try self.emitAddressOf(operand);
                    return self.w.writeAll(")");
                }
                self.bare = bare;
                if (tail and self.ptr_tail) try self.emitValue(operand, true) else try self.emitMoved(operand);
            },
            .share => try self.emitShare(sexp),
            .box => try self.emitBox(sexp),
            .clone => {
                // `+b` of a viewed handle clones the handle it views.
                const operand = ir.Clone.operand(sexp);
                const ty = self.typeOf(operand).?;
                switch (self.facts.cloneable(ty)) {
                    .bump => switch (self.facts.types.get(self.peelViews(ty))) {
                        .optional => {
                            try self.w.writeAll("rig.cloneOptional(");
                            try self.emitBare(operand);
                            try self.w.writeAll(")");
                        },
                        .shared => {
                            try self.emitExpr(operand);
                            try self.w.writeAll(".cloneStrong()");
                        },
                        else => {
                            try self.emitExpr(operand);
                            try self.w.writeAll(".cloneWeak()");
                        },
                    },
                    // `+t` of a String copies its bytes, and `+s` of a `?String`
                    // view makes a String of them.
                    .text => if (self.facts.unwrapViews(ty) == self.facts.types.string_view_id) {
                        try self.w.writeAll("rig.String.of(.{ ");
                        try self.emitBare(operand);
                        try self.w.writeAll(" })");
                    } else {
                        try self.emitExpr(operand);
                        try self.w.writeAll(".clone()");
                    },
                    // Each part cloned as `+` clones it.
                    .deep => {
                        try self.w.writeAll("rig.cloneValue(&(");
                        try self.emitExpr(operand);
                        try self.w.writeAll("))");
                    },
                    // A generic `T` as each instance clones it, which
                    // copies what copies (`rig.cloneAs`).
                    .depends => {
                        try self.w.writeAll("rig.cloneAs(");
                        try self.emitTypeTy(self.typeOf(sexp).?);
                        try self.w.writeAll(", ");
                        try self.emitExpr(operand);
                        try self.w.writeAll(")");
                    },
                    .copy => try self.emitExpr(operand),
                    .no => return self.unsupported(sexp, "a clone of a value that moves"),
                }
            },
            .weak => {
                try self.emitExpr(ir.Weak.operand(sexp));
                try self.w.writeAll(".weakRef()");
            },
            .call => if (self.facts.elemCallOf(self.facts.calleeOf(sexp))) |ec|
                try self.emitElemCall(sexp, ec)
            else if (self.simdConversion(sexp)) |vt| {
                // `Simd[T, n](a)`: the vector of an array's elements.
                try self.writeVectorOpen(vt);
                try self.emitBare(ir.Call.args(sexp)[0]);
                try self.w.writeAll("))");
            }
            else if (try self.hoistsArgs(sexp))
                try self.emitHoistedCall(sexp)
            else
                try self.emitCallDirect(sexp),
            // Compile-time arguments are emitted by the call or type that
            // takes them; sema rejects a bracket list as a value.
            .inst => return self.unsupported(sexp, "a bracket list of compile-time arguments as a value"),
            .ct_call => return self.emitCtCall(self.facts.ctValueOf(sexp) orelse return self.unsupported(sexp, "a compile-time call the checker did not compute")),
            .member, .index => {
                if (self.facts.instanceOf(sexp) != null) return self.unsupported(sexp, "a bracket list of compile-time arguments as a value");
                // A field or element holding a write view denotes the
                // viewed value, unless the pointer itself is wanted.
                const deref = self.isPtrViewExpr(sexp) and !(tail and self.ptr_tail);
                const generic = if (deref) self.genericReadViewOf(sexp) else null;
                // On a `match` subject's path, a generic read view is
                // reached where it is held, never copied.
                const in_place = generic != null and self.onSubjectPath(sexp);
                if (generic) |inner| if (in_place) try self.writeViewedPtrOpen(inner) else try self.writeViewedOpen(inner);
                if (head == .member) try self.emitMember(sexp) else try self.emitIndex(sexp, self.place_chain);
                if (in_place) try self.w.writeAll(").*") else if (generic != null) try self.w.writeAll(")") else if (deref) try self.w.writeAll(".*");
            },
            .builtin => try self.emitBuiltin(sexp),
            .propagate => {
                const operand = ir.Propagate.value(sexp);
                const saved = self.fail_slot;
                defer self.fail_slot = saved;
                // The function's own slot goes on to the call; a function
                // with none, which fails with no fields, lends a slot of
                // its own to a call that takes one.
                const fails_out = self.failsWithFieldsCall(operand);
                if (fails_out and self.fun.has_out) self.fail_slot = .{ .call = operand, .expr = self.fun.out_name };
                try self.w.writeAll("try ");
                const own = if (fails_out and !self.fun.has_out) try self.openCatchSlot(operand) else null;
                try self.emitExpr(operand);
                try self.closeCatchSlot(own);
            },
            .propagate_none => {
                const operand = ir.PropagateNone.value(sexp);
                try self.w.writeAll("(");
                const some = try self.openSome(operand);
                try self.emitExpr(operand);
                try self.closeSome(some);
                try self.w.writeAll(" orelse ");
                try self.writeReturnNone();
                try self.w.writeAll(")");
            },
            .neg => {
                const operand = ir.Neg.operand(sexp);
                // Zig rejects the literal `-0` as ambiguous; `0 - 0` is 0.
                if (operand == .src and isIntZeroText(self.srcText(operand))) return self.w.writeAll("0");
                if (self.laneHelper(sexp, .neg)) |helper| {
                    try self.w.print("{s}(", .{helper});
                    try self.emitBare(operand);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll("-");
                try self.emitExpr(operand);
            },
            .not => {
                try self.w.writeAll("!");
                try self.emitExpr(ir.Not.operand(sexp));
            },
            .enum_lit => {
                const name = self.srcText(ir.EnumLit.name(sexp));
                if (self.typeOf(sexp)) |t| if (self.isErrorSetTy(t)) return self.writeErrorMemberValue(self.peelViews(t), name, sexp);
                try self.w.print(".{f}", .{ident(name)});
            },
            // `:width`: the tag `__rig_sym.Symbol.@"width"`, never its id.
            .symbol => {
                self.uses_symbols = true;
                try self.w.print("__rig_sym.Symbol.@\"{s}\"", .{self.srcText(ir.Symbol.name(sexp))});
            },
            .@"+", .@"-", .@"*", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^" => try self.emitInfix(sexp, bare),
            .@"+%", .@"-%", .@"*%", .@"+|", .@"-|" => {
                if ((head == .@"+|" or head == .@"-|") and self.isSimd(self.typeOf(sexp))) {
                    try self.w.writeAll(if (head == .@"+|") "rig.vecAddSat(" else "rig.vecSubSat(");
                    try self.emitBare(ir.get(sexp, .left));
                    try self.w.writeAll(", ");
                    try self.emitBare(ir.get(sexp, .right));
                    return self.w.writeAll(")");
                }
                // In the expression's type, so that literal operands wrap
                // or saturate as it does rather than as a Zig `comptime_int`.
                if (!bare) try self.w.writeAll("(");
                try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.int_id);
                try self.emitBare(ir.get(sexp, .left));
                try self.w.print(") {s} ", .{@tagName(head)});
                try self.emitExpr(ir.get(sexp, .right));
                if (!bare) try self.w.writeAll(")");
            },
            .@"and", .@"or" => {
                if (!bare) try self.w.writeAll("(");
                try self.emitExpr(ir.get(sexp, .left));
                try self.w.writeAll(if (head == .@"and") " and " else " or ");
                try self.emitExpr(ir.get(sexp, .right));
                if (!bare) try self.w.writeAll(")");
            },
            .@"<<", .@"<<%", .@">>" => {
                // Like `+`, a left shift that loses bits (or the sign)
                // overflows (`@shlExact`); `<<%` drops them, as Zig's `<<`
                // does. The shift amount is cast to the width Zig requires,
                // so one at or over the width panics in either; the shifted
                // value has the expression's type.
                if (self.isSimd(self.typeOf(sexp))) {
                    try self.w.print("{s}(", .{vecShift(head)});
                    try self.emitBare(ir.get(sexp, .left));
                    try self.w.writeAll(", ");
                    try self.emitBare(ir.get(sexp, .right));
                    return self.w.writeAll(")");
                }
                const shl = head == .@"<<";
                const wrap = head == .@"<<%";
                const parens = !shl and !bare;
                if (parens) try self.w.writeAll("(");
                if (shl) try self.w.writeAll("@shlExact(");
                try self.writeAsOpen(self.typeOf(sexp) orelse self.facts.types.int_id);
                try self.emitBare(ir.get(sexp, .left));
                try self.w.writeAll(if (shl) "), " else if (wrap) ") << " else ") >> ");
                const amount = ir.get(sexp, .right);
                const through = try self.openUnsignedCast(amount, self.typeOf(amount), null);
                try self.emitBare(amount);
                try self.closeUnsignedCast(through);
                if (shl) try self.w.writeAll(")");
                if (parens) try self.w.writeAll(")");
            },
            .@"/", .@"%" => try self.emitDivision(sexp),
            .@"??" => {
                const left = ir.@"??".left(sexp);
                const right = ir.@"??".right(sexp);
                // Where the fallback is itself a `T?`, so is the value:
                // both sides are tested, and the result packed.
                const packed_into = self.optionalFallback(sexp);
                if (packed_into) |o| {
                    try self.w.writeAll("rig.pack(");
                    try self.emitTypeTy(o);
                    try self.w.writeAll(", ");
                }
                try self.w.writeAll("(");
                const some = try self.openSome(left);
                try self.emitFallbackHolder(sexp, left);
                try self.closeSome(some);
                try self.w.writeAll(" orelse ");
                const some_right = packed_into != null and self.typeOf(right) != self.facts.types.noreturn_id;
                if (some_right) try self.w.writeAll("rig.some(");
                try self.emitValue(right, true);
                if (some_right) try self.w.writeAll(")");
                try self.w.writeAll(")");
                if (packed_into != null) try self.w.writeAll(")");
            },
            .@"catch" => {
                // `(catch expr name? handler)`: the handler replaces the
                // value. A named error is held as the callee's set:
                // `anyerror` for a `T!`.
                const handler = ir.Catch.handler(sexp);
                if (self.catchGivesNothing(sexp)) return self.emitCatchStatement(sexp);
                // Where the handler is a `T?` and the value a `T!`, the
                // value is one too: the handler is tested, and the result
                // packed.
                const packed_into = self.optionalHandler(sexp);
                const some_handler = packed_into != null and self.typeOf(handler) != self.facts.types.noreturn_id;
                // A call that may fail with fields is lent a slot of the
                // catch's own.
                const slot = try self.openCatchSlot(ir.Catch.value(sexp));
                if (packed_into) |o| {
                    try self.w.writeAll("rig.pack(");
                    try self.emitTypeTy(o);
                    try self.w.writeAll(", ");
                }
                try self.w.writeAll("(");
                try self.emitFallbackHolder(sexp, ir.Catch.value(sexp));
                try self.w.writeAll(" catch ");
                const name = ir.Catch.name(sexp);
                const sym: ?SymbolId = if (name != .nil) self.facts.symbolOf(name) else null;
                if (sym != null and self.usage.used.contains(sym.?)) {
                    const tmp = try self.hiddenStorage(sexp, .error_value, .owned, .next);
                    try self.w.print("|{s}| ", .{tmp});
                    try self.pushScope();
                    const binding = try self.catchBinding(sym.?, name, tmp, if (slot) |s| s.name else null);
                    if (some_handler) try self.w.writeAll("rig.some(");
                    try self.emitValueBlock(handler, binding, self.typeOf(sexp));
                    if (some_handler) try self.w.writeAll(")");
                    try self.popScope();
                } else {
                    // A catch that binds no error drops its fields first.
                    if (slot) |s| try self.w.print("|{s}_c| if (rig.dropFailure({s}_c, &{s})) ", .{ s.name, s.name, s.name });
                    if (some_handler) try self.w.writeAll("rig.some(");
                    try self.emitValue(handler, true);
                    if (some_handler) try self.w.writeAll(")");
                    if (slot != null) try self.w.writeAll(" else unreachable");
                }
                try self.w.writeAll(")");
                if (packed_into != null) try self.w.writeAll(")");
                try self.closeCatchSlot(slot);
            },
            .@"if", .match => {
                // Literal branches under a run-time condition need the
                // result's type spelled out.
                const num = self.numericValueTy(sexp);
                if (num) |t| {
                    try self.writeAsOpen(t);
                } else if (!bare and head == .@"if") try self.w.writeAll("(");
                if (head == .@"if") try self.emitIfExpr(sexp) else try self.emitMatch(sexp, true, null);
                if (num != null) try self.w.writeAll(")") else if (!bare and head == .@"if") try self.w.writeAll(")");
            },
            .block => try self.emitValueBlock(sexp, .{}, self.typeOf(sexp)),
            .raw_block => try self.emitValueBlock(ir.RawBlock.body(sexp), .{}, self.typeOf(sexp)),
            .@"while", .@"for", .labeled => if (facts.syntax.hasValueBreaks(self.source, sexp)) try self.emitLoopValue(sexp) else return self.unsupported(sexp, "a loop without a value in value position"),
            .array => if (try self.hoistsArgs(sexp)) try self.emitHoistedArray(sexp) else try self.emitArray(sexp),
            .array_fill => try self.emitArrayFill(sexp),
            // A jump as a fallback (`?? return`, `catch break`): a block
            // that leaves, which Zig types as `noreturn`.
            .@"return", .@"break", .@"continue" => {
                try self.w.writeAll("{ ");
                try self.emitStmt(sexp);
                try self.w.writeAll(" }");
            },
            // A call Zig types as `noreturn`, which stands for any value.
            .panic => try self.emitPanic(sexp),
            else => return self.unsupported(sexp, "this expression"),
        }
    }

    /// A `catch` whose value goes nowhere, with a handler that gives
    /// nothing, though its value gives something (`Checker.synthCatch`).
    fn catchGivesNothing(self: *Emitter, sexp: Sexp) bool {
        if (self.typeOf(sexp) != self.facts.types.void_id) return false;
        const value_ty = self.typeOf(ir.Catch.value(sexp)) orelse return false;
        return switch (self.facts.types.get(value_ty)) {
            .fallible => |inner| inner.ok != self.facts.types.void_id,
            else => false,
        };
    }

    /// `run() catch |e| print(e)` whose value goes nowhere: Zig's `if` on
    /// the error union, which drops a value and runs the handler on an
    /// error, both branches giving nothing.
    fn emitCatchStatement(self: *Emitter, sexp: Sexp) Error!void {
        const handler = ir.Catch.handler(sexp);
        const ok = try self.fresh("__rig_ok");
        const kept = try self.fresh("__rig_kept");
        const slot = try self.openCatchSlot(ir.Catch.value(sexp));
        try self.w.writeAll("(if (");
        try self.emitFallbackHolder(sexp, ir.Catch.value(sexp));
        try self.w.print(") |{s}| {{ var {s} = {s}; rig.drop(&{s}); }} else ", .{ ok, kept, ok, kept });
        const name = ir.Catch.name(sexp);
        const sym: ?SymbolId = if (name != .nil) self.facts.symbolOf(name) else null;
        if (sym != null and self.usage.used.contains(sym.?)) {
            const tmp = try self.hiddenStorage(sexp, .error_value, .owned, .next);
            try self.w.print("|{s}| ", .{tmp});
            try self.pushScope();
            const binding = try self.catchBinding(sym.?, name, tmp, if (slot) |s| s.name else null);
            try self.emitValueBlock(handler, binding, self.facts.types.void_id);
            try self.popScope();
        } else if (slot) |s| {
            // A catch that binds no error drops its fields first.
            try self.w.print("|{s}_c| if (rig.dropFailure({s}_c, &{s})) ", .{ s.name, s.name, s.name });
            try self.emitValueBlock(handler, .{}, self.facts.types.void_id);
            try self.w.writeAll(" else unreachable");
        } else {
            try self.w.writeAll("|_| ");
            try self.emitValueBlock(handler, .{}, self.facts.types.void_id);
        }
        try self.w.writeAll(")");
        try self.closeCatchSlot(slot);
    }

    /// A statement that gives a value (`facts.syntax.yieldsValue`).
    fn yieldsValue(self: *Emitter, s: Sexp) bool {
        return facts.syntax.yieldsValue(self.source, s);
    }

    /// `storage.isNoneLeaf`.
    fn isNoneLeaf(self: *Emitter, e: Sexp) bool {
        return self.facts.isNoneLeaf(e);
    }

    /// `&place`, or the pointer itself when the place is already one. A
    /// value that branches, read where its leaves are, is addressed at
    /// the leaf it takes (`emitLeafPtr`), never through Zig's address of
    /// the branching expression, which may be a constant.
    fn emitAddressOf(self: *Emitter, place: Sexp) Error!void {
        if (self.hoistedOf(place)) |h| return self.w.print("{s}{s}", .{ if (h.ptr) "" else "&", h.name });
        if (try self.reachesLeaf(place)) return self.emitLeafPtr(place, self.typeOf(place).?);
        if (place == .src) if (self.localOf(place)) |local| {
            if (local.is_ptr) return self.w.writeAll(local.zig_name);
        };
        if (self.isPtrViewExpr(place)) return self.emitWriteViewPtr(place);
        try self.w.writeAll("&");
        try self.emitPlace(place);
    }

    /// The runtime helper that checks the arithmetic `e` on the integer
    /// lanes of a vector, or null when `e` is not that (`storage.laneChecked`,
    /// a recorded fact). Zig's own vector `+`, `-`, `*`, and `-` test LLVM's
    /// overflow bits, which aarch64 gets wrong for wide byte vectors (see
    /// `rig.vecAdd`).
    fn laneHelper(self: *Emitter, e: Sexp, op: Tag) ?[]const u8 {
        if (!(self.facts.laneChecked(e) orelse false)) return null;
        return switch (op) {
            .@"+" => "rig.vecAdd",
            .@"-" => "rig.vecSub",
            .@"*" => "rig.vecMul",
            .neg => "rig.vecNeg",
            else => unreachable,
        };
    }

    /// A binary operator node: `(op left right)`.
    fn emitInfix(self: *Emitter, sexp: Sexp, bare: bool) Error!void {
        try self.inUnit(sexp);
        const kind = sexp.kind().?;
        const op = @tagName(kind);
        const is_eq = kind == .@"==" or kind == .@"!=";
        const operands = [2]Sexp{ ir.get(sexp, .left), ir.get(sexp, .right) };
        // An optional resource made here and compared with `none` is
        // dropped by the test.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const other = operands[1 - i];
            if (!self.isNoneLeaf(other) or !try self.dropsWhenTested(operands[i])) continue;
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll("rig.isNone(");
            try self.emitBare(operands[i]);
            return self.w.writeAll(")");
        };
        // `none` beside an optional that goes through the helpers tests
        // what `rig.some` gives.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            if (!self.isNoneLeaf(operands[1 - i]) or !self.routedOptional(self.typeOf(operands[i]))) continue;
            if (!bare) try self.w.writeAll("(");
            try self.w.writeAll("rig.some(");
            try self.emitBare(operands[i]);
            try self.w.print(") {s} null", .{op});
            if (!bare) try self.w.writeAll(")");
            return;
        };
        // `e == E.name` on an error that may carry fields tests its code
        // and never its fields.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const value = operands[1 - i];
            const member = operands[i];
            const vt = self.typeOf(value) orelse continue;
            if (!self.isErrorValueTy(self.peelViews(vt)) or !self.namesErrorMember(member) or member.isKind(.call)) continue;
            const temp = try self.dropsWhenTested(value);
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll(if (temp) "rig.isErrorDiscard(" else "rig.isError(");
            try self.emitExpr(value);
            try self.w.writeAll(", ");
            const set = self.peelViews(self.typeOf(member) orelse return self.unsupported(member, "an untyped error"));
            const name = if (member.isKind(.enum_lit)) ir.EnumLit.name(member) else ir.Member.name(member);
            try self.writeError(set, self.srcText(name), member);
            return self.w.writeAll(")");
        };
        // A bare `.variant` beside a payload enum tests the variant only.
        if (is_eq) for ([2]usize{ 0, 1 }) |i| {
            const value = operands[1 - i];
            if (!operands[i].isKind(.enum_lit) or !self.isPayloadEnumOperand(value)) continue;
            // A value made here that owns a resource is dropped once
            // tested.
            const temp = try self.dropsWhenTested(value);
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll(if (temp) "rig.isVariantDiscard(" else "rig.isVariant(");
            try self.emitExpr(value);
            try self.w.writeAll(", ");
            try self.emitExpr(operands[i]);
            return self.w.writeAll(")");
        };
        // `x == K.name`, a member test: which variant `x` holds.
        if (is_eq and self.facts.isMemberTest(sexp)) {
            const i: usize = if (operands[1].isKind(.member)) 1 else 0;
            const temp = try self.dropsWhenTested(operands[1 - i]);
            if (kind == .@"!=") try self.w.writeAll("!");
            try self.w.writeAll(if (temp) "rig.isVariantDiscard(" else "rig.isVariant(");
            try self.emitExpr(operands[1 - i]);
            return self.w.print(", .{f})", .{ident(self.srcText(ir.Member.name(operands[i])))});
        }
        // Two errors that may carry fields compare member and fields
        // through the glue (`ErrorValue.__rig_own_eq`); an optional of
        // one holds one too, which `rig.eql` unwraps.
        if (is_eq and (self.holdsErrorValueOpt(operands[0]) or self.holdsErrorValueOpt(operands[1]))) {
            if (kind == .@"!=") try self.w.writeAll("!");
            // Beside a code-only error, an error that carries fields
            // compares its code, as its member's fields are none.
            for ([2]usize{ 0, 1 }) |i| if (!self.holdsErrorValueOpt(operands[i])) {
                try self.w.writeAll("rig.isError(");
                try self.emitExpr(operands[1 - i]);
                try self.w.writeAll(", ");
                try self.emitExpr(operands[i]);
                return self.w.writeAll(")");
            };
            return self.emitCall2("rig.eql(", operands, ")");
        }
        if (is_eq and self.comparesStructurally(operands)) {
            if (kind == .@"!=") try self.w.writeAll("!");
            return self.emitCall2("rig.eql(", operands, ")");
        }
        if (!is_eq) if (self.orderOperator(kind, operands)) |order| {
            // Strings and byte slices order by their bytes.
            if (order.bytes) {
                if (!bare) try self.w.writeAll("(");
                try self.emitCall2("std.mem.order(u8, ", operands, order.test_);
                if (!bare) try self.w.writeAll(")");
                return;
            }
            // A generic `T` orders as its instance does, and a plain
            // enum by its variants' values.
            try self.w.writeAll("rig.compare(");
            try self.emitExpr(operands[0]);
            try self.w.print(", .{s}, ", .{order.op});
            try self.emitExpr(operands[1]);
            return self.w.writeAll(")");
        };
        // An add known not to overflow (`provenOf`).
        if (kind == .@"+" and self.provenOf(sexp).no_overflow) return self.emitCall2("rig.addProven(", operands, ")");
        // An add known not to overflow while a flag holds (`provenIf`).
        if (kind == .@"+") if (self.provenIf(sexp)) |c| if (c.tests.no_overflow) return self.emitCall2("rig.addIf(", operands, try self.fmt(", {s})", .{c.flag}));
        if (self.laneHelper(sexp, kind)) |helper| {
            try self.w.print("{s}(", .{helper});
            try self.emitBare(operands[0]);
            try self.w.writeAll(", ");
            try self.emitBare(operands[1]);
            return self.w.writeAll(")");
        }
        // Masks combine and compare through the runtime (`rig.Mask`), and
        // a comparison of other vectors gives its lanes as a mask.
        if (self.isMask(self.typeOf(sexp))) {
            if (self.isMask(self.typeOf(operands[0])) or self.isMask(self.typeOf(operands[1]))) {
                const f = maskOperator(kind) orelse return self.unsupported(sexp, "this operator on masks");
                return self.emitCall2(f, operands, ")");
            }
            try self.w.writeAll("rig.mask(");
            try self.emitExpr(operands[0]);
            try self.w.print(" {s} ", .{op});
            try self.emitExpr(operands[1]);
            return self.w.writeAll(")");
        }
        if (!bare) try self.w.writeAll("(");
        try self.emitExpr(operands[0]);
        try self.w.print(" {s} ", .{op});
        try self.emitExpr(operands[1]);
        if (!bare) try self.w.writeAll(")");
    }

    /// `a / b` and `a % b` (see `divBuiltin`).
    fn emitDivision(self: *Emitter, sexp: Sexp) Error!void {
        const left = ir.get(sexp, .left);
        const right = ir.get(sexp, .right);
        const builtin = self.divBuiltin(sexp.kind().?, left, right) orelse return self.emitInfix(sexp, false);
        try self.w.print("{s}(", .{builtin});
        try self.emitBare(left);
        try self.w.writeAll(", ");
        try self.emitBare(right);
        try self.w.writeAll(")");
    }

    /// `[a, b, c]` → `[_]T{ a, b, c }`.
    fn emitArray(self: *Emitter, sexp: Sexp) Error!void {
        const elems = ir.Array.elems(sexp);
        const ty = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped array literal");
        const arr = self.facts.types.get(self.peelViews(ty));
        if (arr != .array) return self.unsupported(sexp, "this array literal");
        try self.w.writeAll("[_]");
        try self.emitTypeTy(arr.array.elem);
        try self.w.writeAll("{");
        for (elems, 0..) |e, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitStored(e);
        }
        try self.w.writeAll(if (elems.len > 0) " }" else "}");
    }

    /// An array literal whose elements are evaluated first (`hoistsArgs`):
    /// each that is not pure into a temporary in its turn, as a call's
    /// arguments are (`hoist`), and the array built of them last, so an
    /// element that leaves drops the owned ones made before it.
    /// `[String("a"), mk()!]`:
    ///
    ///     __rig_array_N: {
    ///         var __rig_arg_N_0: rig.String = rig.String.of(.{ "a" });
    ///         var __rig_live_N_0 = true;
    ///         defer if (__rig_live_N_0) rig.drop(&__rig_arg_N_0);
    ///         var __rig_arg_N_1: rig.String = try mk();
    ///         ...
    ///         break :__rig_array_N [_]rig.String{ rig.take(&__rig_live_N_0, __rig_arg_N_0), ... };
    ///     }
    fn emitHoistedArray(self: *Emitter, sexp: Sexp) Error!void {
        const id = self.nextId();
        try self.w.print("__rig_array_{d}: ", .{id});
        try self.openBrace();
        const first = self.hoisted.items.len;
        for (ir.Array.elems(sexp), 0..) |e, i| {
            if (try self.isPureArg(e)) continue;
            try self.hoist(.{ .node = e, .name = "", .flag = try self.fmt("__rig_live_{d}_{d}", .{ id, i }) }, .{ .pair = .{ id, @intCast(i) } }, &.{}, 0, true);
        }
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_array_{d} ", .{id});
        try self.emitArray(sexp);
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.writeAll(";\n");
        try self.closeBrace();
    }

    /// `[n of x]` → `@as([n]T, @splat(x))`.
    fn emitArrayFill(self: *Emitter, sexp: Sexp) Error!void {
        const ty = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped array literal");
        try self.w.writeAll("@as(");
        try self.emitTypeTy(self.peelViews(ty));
        try self.w.writeAll(", @splat(");
        try self.emitBare(ir.ArrayFill.value(sexp));
        try self.w.writeAll("))");
    }

    /// `x[i]`: bounds-checked element of an array, slice, string, or
    /// `List` of plain data. As a place, a `List` element is `x.slot(i).*`,
    /// and the base of any element is a place too.
    fn emitIndex(self: *Emitter, sexp: Sexp, as_place: bool) Error!void {
        try self.inUnit(sexp);
        const base = ir.Index.object(sexp);
        const index = ir.Index.index(sexp);
        const base_ty = self.typeOf(base);
        const saved_chain = self.place_chain;
        defer self.place_chain = saved_chain;
        self.place_chain = as_place;

        if (index.isKind(.@"..")) return self.emitSlice(sexp, base, base_ty, index);
        // A lane of a vector is a value, read with its index checked
        // (Zig indexes a vector only at a constant).
        if (base_ty != null and self.facts.types.get(self.peelViews(base_ty.?)) == .simd) {
            self.place_chain = false;
            try self.w.writeAll("rig.lane(");
            try self.emitBare(base);
            try self.w.writeAll(", ");
            try self.emitBare(index);
            return self.w.writeAll(")");
        }
        // An element of a Cell's List is a copy; `c[i] = x` is `emitPlaceAssign`'s.
        if (base_ty != null and self.isCellListTy(base_ty.?)) {
            try self.emitCellPtr(base);
            try self.w.writeAll(".listAt(");
            self.place_chain = false;
            try self.emitBare(index);
            return self.w.writeAll(")");
        }
        // A shared handle's element is its value's.
        const held_ty: ?TypeId = if (base_ty) |t| self.facts.unwrapReadAccess(t) else null;
        // An element that is not copied (`readsInPlace`) is reached
        // where it is, as a field is: never a copy of its bits.
        const in_place = as_place or self.elemInPlace(sexp);
        // A table's slot: by a `Slot[n]`, with no test, unless every test
        // is made (`no_proofs`); by an integer, tested against `n`.
        if (held_ty != null and self.facts.tableElem(self.peelViews(held_ty.?)) != null) {
            try self.emitIndexBase(base, base_ty, .expr);
            // A slot a write reaches is reached to write; every other is
            // read-only, so a table held as written never grows for a read.
            const method = if (!in_place) "at" else if (self.facts.isTableWrite(sexp)) "slot" else "constSlot";
            const by_slot = if (self.typeOf(index)) |t| self.facts.types.get(t) == .slot else false;
            try self.w.print(".{s}{s}(", .{ method, if (by_slot and !self.no_proofs) "" else "Int" });
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(if (in_place) ").*" else ")");
            return;
        }
        if (held_ty != null and self.isListTy(held_ty.?)) {
            try self.emitIndexBase(base, base_ty, .expr);
            const method = if (!in_place) "at" else if (self.read_place or !as_place or self.throughReadView(base)) "constSlot" else "slot";
            // The tests known to pass are omitted (`provenOf`), and those
            // known while a flag holds, while it does (`provenIf`).
            const proven = provenTests(self.provenOf(sexp));
            const cond = self.provenIf(sexp);
            try self.w.print(".{s}{s}(", .{ method, if (cond != null) "If" else if (proven != null) "Proven" else "" });
            // The index itself is a value, even inside an assignment target.
            self.place_chain = false;
            try self.emitBare(index);
            if (cond) |c| {
                try self.w.print(", {s}{s}, .{s}, {s}", .{ if (proven != null) "." else "", proven orelse "null", provenTests(c.tests).?, c.flag });
            } else if (proven) |p| try self.w.print(", .{s}", .{p});
            try self.w.writeAll(if (in_place) ").*" else ")");
            return;
        }
        const array_len: ?TypeId = if (held_ty) |t| switch (self.facts.types.get(t)) {
            .array => |a| a.len,
            else => null,
        } else null;
        // A value read from a constant is a run-time value (`readsFixed`).
        const fixed = !in_place and self.readsFixed(sexp, base, index);
        if (fixed) try self.w.writeAll("rig.rt(");
        const n = array_len orelse {
            // A string or slice: its length is only known when it runs,
            // and `rig.at` and `rig.elemPtr` evaluate it once. Only a `![]T`
            // is assigned through.
            // A test known to pass is omitted (`provenOf`), and one known
            // while a flag holds, while it does (`provenIf`).
            const proven = provenTests(self.provenOf(sexp));
            const cond = self.provenIf(sexp);
            try self.w.print("rig.{s}{s}(", .{ if (in_place) "elemPtr" else "at", if (cond != null) "If" else if (proven != null) "Proven" else "" });
            try self.emitIndexBase(base, base_ty, .bare);
            try self.w.writeAll(", ");
            self.place_chain = false;
            try self.emitBare(index);
            if (cond) |c| {
                try self.w.print(", {s}{s}, .{s}, {s}", .{ if (proven != null) "." else "", proven orelse "null", provenTests(c.tests).?, c.flag });
            } else if (proven) |p| try self.w.print(", .{s}", .{p});
            try self.w.writeAll(if (in_place) ").*" else ")");
            if (fixed) try self.w.writeAll(")");
            return;
        };
        const may_be_empty = switch (self.facts.types.get(n)) {
            .ct_value => |v| v.int == 0,
            else => true,
        };
        if (may_be_empty) {
            // Zig rejects indexing an empty array, and a length that is a
            // compile-time parameter may be 0: the element is reached
            // through a slice of the array.
            try self.w.writeAll("rig.elems(");
            const saved_read = self.read_place;
            if (!as_place) self.read_place = true;
            try self.emitIndexBase(base, base_ty, .address);
            self.read_place = saved_read;
            try self.w.writeAll(")[rig.index(");
            self.place_chain = false;
            try self.emitBare(index);
            try self.w.writeAll(", ");
            try self.emitTypeTy(n);
            try self.w.writeAll(")]");
            if (fixed) try self.w.writeAll(")");
            return;
        }
        // An array literal is indexed through parentheses: `([_]T{ ... })[i]`.
        const literal = base.isKind(.array);
        if (literal) try self.w.writeAll("(");
        try self.emitIndexBase(base, base_ty, .expr);
        if (literal) try self.w.writeAll(")");
        try self.w.writeAll("[");
        self.place_chain = false;
        // Sema checked a constant index against a known length.
        if (isNonNegativeIntLiteral(self.source, index)) {
            try self.emitExpr(index);
        } else {
            try self.w.writeAll("rig.index(");
            try self.emitBare(index);
            try self.w.writeAll(", ");
            try self.emitTypeTy(n);
            try self.w.writeAll(")");
        }
        try self.w.writeAll("]");
        if (fixed) try self.w.writeAll(")");
    }

    /// Whether `part`, an element of `base` at `index`, is a value of
    /// plain data that Zig would know at compile time: both are built
    /// only from constants (`isZigComptimeIn`), as in `table[0]` for a
    /// module constant `table`. Rig folds only the constant scalars it
    /// checks itself, so Zig must not fold the rest: a part of a constant
    /// is read through `rig.rt`, which keeps it a run-time value, as an
    /// inlined function's result is. A part that is itself an aggregate
    /// is left bare: what reads it, binds it, or matches it makes the
    /// run-time value (`isZigComptimeIn` in `emitBind`, `emitMatchSubject`).
    fn readsFixed(self: *Emitter, part: Sexp, base: Sexp, index: Sexp) bool {
        return !self.keep_comptime and self.isScalarPart(part) and isZigComptimeIn(self, base, 0) and isZigComptimeIn(self, index, 0);
    }

    /// The start of a `value` read as a run-time value (`rig.rt`), when
    /// `fixed`: a scalar is given its type first, since a literal alone
    /// is a compile-time integer or float, which `rig.rt` would keep.
    fn openFixed(self: *Emitter, fixed: bool, value: Sexp) Error!void {
        if (!fixed) return;
        try self.w.writeAll("rig.rt(");
        if (!self.isScalarPart(value)) return;
        const t = self.typeOf(value).?;
        const types = self.facts.types;
        try self.writeAsOpen(switch (types.get(t)) {
            .int_literal => types.int_id,
            .float_literal => types.float_id,
            else => t,
        });
    }

    fn closeFixed(self: *Emitter, fixed: bool, value: Sexp) Error!void {
        if (!fixed) return;
        try self.w.writeAll(if (self.isScalarPart(value)) "))" else ")");
    }

    /// `part`'s type is a number or a `Bool`, or an optional of one: what
    /// an operator can fail on once Zig knows it.
    fn isScalarPart(self: *Emitter, part: Sexp) bool {
        var t = self.peelViews(self.typeOf(part) orelse return false);
        while (true) switch (self.facts.types.get(t)) {
            .optional => |inner| t = inner,
            .int, .float, .int_literal, .float_literal, .bool, .slot => return true,
            else => return false,
        };
    }

    /// Whether place `e` is reached through a read view or a shared
    /// handle, whose value is read-only: an element on the way is
    /// reached through `constSlot`.
    fn throughReadView(self: *Emitter, e: Sexp) bool {
        var p = e;
        while (true) {
            if (p.isKind(.read)) return true;
            if (self.typeOf(p)) |t| switch (self.facts.types.get(t)) {
                .read_view, .shared => return true,
                else => {},
            };
            if (!p.isKind(.member) and !p.isKind(.index)) return false;
            p = ir.get(p, .object);
        }
    }

    /// Whether element `e` is read where it is rather than copied
    /// (`copiesElem`). (No element holds a Cell by value: a Cell lives
    /// only behind a shared handle.)
    fn elemInPlace(self: *Emitter, e: Sexp) bool {
        if (self.typeOf(e) == null) return false;
        return !self.facts.copiesElem(e);
    }

    /// The object `base` of an index, emitted `how` the index needs it. A
    /// shared handle is read through its value, as a member read reaches
    /// through it (`writeReach`).
    fn emitIndexBase(self: *Emitter, base: Sexp, base_ty: ?TypeId, how: enum { expr, bare, address }) Error!void {
        if (base_ty) |t| if (self.facts.types.get(self.peelViews(t)) == .shared) {
            if (how == .address) try self.w.writeAll("&");
            try self.emitMemberBase(base, t);
            return self.writeReach(t);
        };
        // A generic view of an array (`rig.ReadView([n]T)`, a pointer
        // or a copy as the instance decides) is indexed as it is: indexing
        // a copy of the whole array would lend its element from the copy.
        if (how == .expr and base == .src) if (self.localOf(base)) |local| if (local.is_ptr and local.ty != null and self.genericReadView(local.ty.?) != null) {
            return self.w.writeAll(local.zig_name);
        };
        // A value that branches is indexed where the leaf it takes is.
        if (try self.reachesLeaf(base)) return self.emitMemberBase(base, base_ty);
        switch (how) {
            .expr => try self.emitBaseExpr(base),
            .bare => try self.emitBare(base),
            .address => try self.emitAddressOf(base),
        }
    }

    /// `base` where a postfix follows it: a value that branches, moved
    /// (`<(a if c else b)`), is emitted as Zig's `if`, which a postfix
    /// would not reach whole, so it is parenthesized.
    fn emitBaseExpr(self: *Emitter, base: Sexp) Error!void {
        const parens = movesCompound(base);
        if (parens) try self.w.writeAll("(");
        try self.emitExpr(base);
        if (parens) try self.w.writeAll(")");
    }

    /// `xs[a..b]` → `rig.slice(items, a, b)`, which checks the bounds;
    /// `xs[a..]` → `rig.slice(items, a, null)`. An array is sliced in
    /// place, through its address; a List through its items.
    fn emitSlice(self: *Emitter, slice: Sexp, base: Sexp, base_ty: ?TypeId, range: Sexp) Error!void {
        self.place_chain = false;
        const writes = self.isWriteSliceExpr(slice);
        try self.w.writeAll(if (writes) "rig.sliceMut(" else "rig.slice(");
        const ty = self.peelViews(base_ty orelse return self.unsupported(base, "a slice of an untyped value"));
        // A constant is sliced where it is stored, not through a copy.
        const saved_rt = self.rt_names;
        self.rt_names = false;
        if (self.isListTy(ty)) {
            try self.emitBaseExpr(base);
            try self.w.writeAll(".items()");
        } else if (self.stringReach(ty)) |reach| {
            try self.emitBaseExpr(base);
            try self.w.print("{s}.bytes()", .{reach});
        } else if (self.facts.types.get(ty) == .array) {
            // A read slice only reads through: a List element on the way
            // is reached through a read-only slot.
            const saved_read = self.read_place;
            self.read_place = !writes;
            try self.emitAddressOf(base);
            self.read_place = saved_read;
        } else try self.emitBare(base);
        self.rt_names = saved_rt;
        // An open start is 0; an open end, `null`, is the length. An
        // inclusive end is one past its bound (`rig.through`).
        for ([2]Sexp{ ir.@"..".left(range), ir.@"..".right(range) }, [2][]const u8{ "0", "null" }, [2]bool{ false, rig.isInclusive(range) }) |bound, open, through| {
            try self.w.writeAll(if (through) ", rig.through(" else ", ");
            if (bound == .nil) try self.w.writeAll(open) else try self.emitBare(bound);
            if (through) try self.w.writeAll(")");
        }
        try self.w.writeAll(")");
    }

    /// `(member obj name)`. A shared handle auto-dereferences through
    /// `.value`; `.len` of an array, slice, string, or List is an `Int`.
    fn emitMember(self: *Emitter, sexp: Sexp) Error!void {
        return self.emitMemberNamed(sexp, self.srcText(ir.Member.name(sexp)));
    }

    /// Member `sexp` read as `field`: the member's own name, or `len` for
    /// the length `is_empty()` compares.
    fn emitMemberNamed(self: *Emitter, sexp: Sexp, field: []const u8) Error!void {
        const obj = ir.Member.object(sexp);
        const obj_ty = self.typeOf(obj);
        // `U8.max`, `F64.min`: a number type's limit.
        if (self.facts.intLimit(sexp)) |limit| return self.emitIntConstant(sexp, limit.v);
        const number_type = if (obj.isKind(.member))
            (if (self.moduleMemberSym(obj)) |m| m.kind == .type_alias else false)
        else
            obj == .src and if (self.facts.symbolOf(obj)) |id| self.facts.symbols.items[id].kind == .type_alias else facts.syntax.isNumericTypeName(self.srcText(obj));
        if (number_type) if (self.typeOf(sexp)) |t| if (self.facts.types.get(t) == .float) {
            try self.writeAsOpen(t);
            try self.w.writeAll(if (std.mem.eql(u8, field, "min")) "-std.math.floatMax(" else "std.math.floatMax(");
            try self.emitTypeTy(t);
            return self.w.writeAll("))");
        };
        // `e.text`: the name of a plain enum value's variant.
        if (self.facts.isEnumText(sexp)) {
            try self.w.writeAll("rig.enumText(");
            try self.emitMemberBase(obj, obj_ty);
            if (obj_ty) |t| try self.writeReach(t);
            return self.w.writeAll(")");
        }
        // `E.name` of an error set.
        if (self.facts.isErrorMember(sexp)) return self.writeErrorMemberValue(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped error"), field, sexp);
        // `Shape.dot` of an enum with payloads names the tag; the value
        // is the union holding it.
        if (obj_ty == null and self.isTypeCallee(obj)) if (self.typeOf(sexp)) |t| if (self.hasPayloadVariants(t)) {
            try self.writeAsOpen(t);
            try self.emitMemberBase(obj, obj_ty);
            return self.w.print(".{f})", .{ident(field)});
        };
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.isCellListTy(obj_ty.?)) {
            try self.emitCellPtr(obj);
            return self.w.writeAll(".listLen()");
        }
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.facts.unwrapAccess(obj_ty.?) == self.facts.types.string_id) {
            try self.emitMemberBase(obj, obj_ty);
            try self.writeReach(obj_ty.?);
            return self.w.writeAll(".length()");
        }
        // The length of a List, a slice, or an array (`rig.lenOf`, which
        // tests it only where it is not held below `max_len`).
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.hasLen(obj_ty.?)) {
            try self.w.writeAll("rig.lenOf(");
            try self.emitMemberBase(obj, obj_ty);
            return self.w.writeAll(")");
        }
        // The length of an array or List behind a shared handle or a box.
        if (std.mem.eql(u8, field, "len") and obj_ty != null and self.hasLenReached(obj_ty.?)) {
            try self.w.writeAll("rig.lenOf(");
            try self.emitMemberBase(obj, obj_ty);
            try self.writeReach(obj_ty.?);
            return self.w.writeAll(")");
        }
        // An imported constant is read at run time, like a local one.
        if (self.rt_names and !self.keep_comptime and self.isModuleValue(obj, sexp)) {
            try self.w.writeAll("rig.rt(");
            try self.writeModuleZig(self.facts.moduleOf(self.facts.symbolOf(obj).?).?);
            return self.w.print(".{f})", .{ident(field)});
        }
        // A field of a value built of constants is a run-time value
        // (`readsFixed`).
        const fixed = obj_ty != null and !self.place_chain and !self.keep_comptime and !self.isModuleValue(obj, sexp) and
            self.isScalarPart(sexp) and isZigComptimeIn(self, obj, 0);
        if (fixed) try self.w.writeAll("rig.rt(");
        try self.emitMemberBase(obj, obj_ty);
        if (obj_ty) |t| if (!self.isBoxMethod(sexp, t, field)) {
            // A consuming method of an owned box's value takes the value
            // out of each box, which is freed.
            if (self.facts.boxedType(t) != null and self.facts.boxedNominal(t) != null and self.facts.methodReceiver(t, field) == .value) {
                var b = t;
                while (self.facts.boxedType(b)) |inner| : (b = inner) try self.w.writeAll(".unbox()");
            } else try self.writeReach(t);
        };
        try self.w.print(".{f}", .{ident(field)});
        if (fixed) try self.w.writeAll(")");
    }

    /// `.value` for each shared handle and box that member access on a
    /// `ty` reaches through (`sema.unwrapAccess`). A box's `.value` is a
    /// pointer, so a handle it holds is dereferenced before its own.
    fn writeReach(self: *Emitter, ty: TypeId) Error!void {
        var t = ty;
        var ptr = false;
        while (true) switch (self.facts.types.get(t)) {
            .read_view, .write_view => |inner| {
                // A view held in a box is a pointer, which the box's
                // pointer reaches; it points at the viewed value.
                if (ptr and self.isPtrViewTy(t)) try self.w.writeAll(".*");
                t = inner;
            },
            .shared => |inner| {
                try self.w.writeAll(if (ptr) ".*.value" else ".value");
                t = inner;
                ptr = false;
            },
            else => {
                t = self.facts.boxedType(t) orelse break;
                try self.w.writeAll(".value");
                ptr = true;
            },
        };
    }

    /// `b.unbox` called: the box's own method, which comes before its
    /// value's methods. A data field of the value named `unbox` is read
    /// through the box.
    fn isBoxMethod(self: *Emitter, member: Sexp, ty: TypeId, name: []const u8) bool {
        if (self.facts.boxedType(self.facts.unwrapReadAccess(ty)) == null or !std.mem.eql(u8, name, "unbox")) return false;
        if (self.facts.lookupDataFieldConst(ty, name) == null) return true;
        const t = self.typeOf(member) orelse return true;
        return self.fnType(t) != null;
    }

    /// `module.name` naming a constant (not a function or a type).
    fn isModuleValue(self: *Emitter, obj: Sexp, member: Sexp) bool {
        if (obj != .src) return false;
        const id = self.facts.symbolOf(obj) orelse return false;
        if (self.facts.symbols.items[id].kind != .module) return false;
        const ty = self.typeOf(member) orelse return false;
        return self.fnType(ty) == null;
    }

    /// The object of a member access. Lend sigils on a receiver are
    /// implicit in Zig's method call syntax; pointers to structs
    /// auto-dereference.
    fn emitMemberBase(self: *Emitter, obj: Sexp, obj_ty: ?TypeId) Error!void {
        const o = lentPlace(obj);
        // The type of the value reached, which a lend of it (`!mk()`, a
        // view of the value it lends) is not.
        const o_ty = if (sameNode(o, obj)) obj_ty else self.typeOf(o);
        if (self.place_chain and o.isKind(.index) and self.facts.instanceOf(o) == null) return self.emitIndex(o, true);
        // A lent to write field or element (`!v[i].bump()`) is changed
        // in place, reached through the element's slot, unless it was
        // hoisted to run before the arguments.
        if (obj.isKind(.write) and (o.isKind(.index) or o.isKind(.member)) and self.hoistedOf(o) == null) return self.emitPlace(o);
        // `Pair[Int, ?String].make(...)`: the instance named.
        if (self.facts.instanceOf(o)) |inst| if (inst == .type) return self.emitTypeTy(inst.type);
        // `Wrap.make(...)` of a generic type: the instance sema inferred.
        if (o == .src) if (self.facts.symbolOf(o)) |id| if (self.facts.symbols.items[id].kind == .generic_type) {
            if (obj_ty) |t| return self.emitTypeTy(t);
        };
        // `m.Wrap.make(...)` of another module's generic type.
        if (o.isKind(.member) and self.isTypeCallee(o)) if (obj_ty) |t| if (self.facts.types.get(t) == .parameterized_nominal) return self.emitTypeTy(t);
        if (o == .src) if (self.localOf(o)) |local| {
            if (local.is_ptr and obj_ty != null and self.isStructLike(obj_ty.?)) return self.w.writeAll(local.zig_name);
            return self.writeLocalPlace(local);
        };
        // A value that branches, read where its leaves are, is reached
        // through the address of the leaf it takes, never a copy.
        // Zig reaches a field through a pointer to a struct, but not
        // through one to a handle (`reachesHandle`).
        if (try self.reachesLeaf(o)) {
            if (self.hoistedOf(o)) |h| try self.w.writeAll(h.name) else try self.emitLeafPtr(o, self.typeOf(o).?);
            if (self.reachesHandle(self.typeOf(o))) try self.w.writeAll(".*");
            return self.derefToHandle(self.typeOf(o));
        }
        // A value that branches is read as its Rig type: Zig would take
        // a field of each branch's own type (a literal's, a `?String`'s);
        // a receiver evaluated first is read where it was kept. One its
        // statement's slot keeps (`sema.dropsTemp`), lent to write
        // (`sema.writesTemp`) or not, is reached in the slot (below),
        // which has that type, never in a copy: a change through it is
        // the temporary's own, which its drop sees.
        if (!self.facts.writesTemp(o) and !self.facts.dropsTemp(o)) if (o.isKind(.@"if") or o.isKind(.match) or o.isKind(.@"??") or o.isKind(.@"catch")) if (o_ty) |t| {
            if (self.hoistedOf(o)) |h| if (h.flag.len == 0) {
                try self.w.writeAll(h.name);
                return self.derefToHandle(t);
            };
            try self.writeAsOpen(t);
            try self.emitExpr(o);
            try self.w.writeAll(")");
            return self.derefToHandle(t);
        };
        const needs_parens = movesCompound(o) or if (o.kind()) |h| switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .neg, .not, .propagate, .call, .array => true,
            else => false,
        } else false;
        if (needs_parens) try self.w.writeAll("(");
        try self.emitExpr(o);
        if (needs_parens) try self.w.writeAll(")");
        // A call yielding a view held by pointer: Zig reaches a field
        // through a pointer to a struct, but not through one to a handle.
        if (o.isKind(.call) and o_ty != null and self.isPtrViewTy(o_ty.?) and !self.isStructLike(o_ty.?)) try self.w.writeAll(".*");
    }

    /// Whether `e` is reached where its leaves are: the recorded decision
    /// (`storage.reachesLeaf`).
    fn reachesLeaf(self: *Emitter, e: Sexp) Error!bool {
        return self.facts.reachesLeaf(e) orelse self.unsupported(e, "a value no checker decided how to reach");
    }

    /// The address of the value `e`, of type `ty`, takes: for a value
    /// that branches, the address of the leaf it takes,
    /// `(if (c) &a else &b)` for `a if c else b`, and for `o ?? d`,
    /// `e catch d`, `o?`, and `e!`, the address of the payload where it
    /// is, `(if (o) |*v| v else &d)`, walked as `storage.leafStep` says. A
    /// place is reached where it is, a value kept in its statement's slot
    /// there, and a jump leaves. Any other value made here is a Zig
    /// temporary of the expression, which may be constant: nothing
    /// changes it (a Cell lives only behind a shared handle).
    fn emitLeafPtr(self: *Emitter, e: Sexp, ty: TypeId) Error!void {
        switch (self.facts.leafStep(e) orelse return self.unsupported(e, "a value reached by address that no checker walked")) {
            .@"if" => {
                try self.w.writeAll("(");
                try self.emitIfYieldAs(e, .leaf_ptr, ty);
                return self.w.writeAll(")");
            },
            .fallback => {
                const holder = if (e.isKind(.@"??")) ir.@"??".left(e) else ir.Catch.value(e);
                const v = try self.hiddenStorage(e, .leaf, .pointer, .next);
                const routed = e.isKind(.@"??") and self.routedOptional(self.typeOf(holder));
                // A catch of a call that may fail with fields holds its
                // slot in a block around the `if`; the value it reaches is
                // kept in the statement's slot, outside the block.
                const slot = if (e.isKind(.@"catch")) try self.openCatchSlot(holder) else null;
                defer if (slot) |sl| {
                    self.fail_slot = sl.saved;
                };
                try self.w.writeAll(if (routed) "(if (rig.somePtr(&" else "(if (");
                try self.emitPayloadHolder(holder);
                try self.w.print("{s} |{s}{s}| {s} else ", .{ if (routed) "))" else ")", if (routed) "" else "*", v, v });
                if (e.isKind(.@"??")) {
                    try self.emitLeafPtr(ir.@"??".right(e), ty);
                    return self.w.writeAll(")");
                }
                const name = ir.Catch.name(e);
                const handler = ir.Catch.handler(e);
                const sym: ?SymbolId = if (name != .nil) self.facts.symbolOf(name) else null;
                if (sym != null and self.usage.used.contains(sym.?)) {
                    const tmp = try self.hiddenStorage(e, .error_value, .owned, .next);
                    try self.w.print("|{s}| ", .{tmp});
                    try self.pushScope();
                    const binding = try self.catchBinding(sym.?, name, tmp, if (slot) |sl| sl.name else null);
                    try self.emitYieldBlock(handler, binding, ty, .leaf_ptr);
                    try self.popScope();
                } else if (slot) |sl| {
                    // A catch that binds no error drops its fields first.
                    try self.w.print("|{s}_c| if (rig.dropFailure({s}_c, &{s})) ", .{ sl.name, sl.name, sl.name });
                    try self.emitYieldBlock(handler, .{}, ty, .leaf_ptr);
                    try self.w.writeAll(" else unreachable");
                } else {
                    try self.w.writeAll("|_| ");
                    try self.emitYieldBlock(handler, .{}, ty, .leaf_ptr);
                }
                try self.w.writeAll(")");
                if (slot != null) try self.w.writeAll("; })");
            },
            .unwrap => {
                const operand = if (e.isKind(.propagate)) ir.Propagate.value(e) else ir.PropagateNone.value(e);
                const v = try self.hiddenStorage(e, .leaf, .pointer, .next);
                if (e.isKind(.propagate)) {
                    // `e!` reached by address lends its call this
                    // function's slot, as a `!` anywhere does.
                    const saved = self.fail_slot;
                    defer self.fail_slot = saved;
                    const fails_out = self.failsWithFieldsCall(operand);
                    if (fails_out and self.fun.has_out) self.fail_slot = .{ .call = operand, .expr = self.fun.out_name };
                    try self.w.writeAll("(if (");
                    const own = if (fails_out and !self.fun.has_out) try self.openCatchSlot(operand) else null;
                    try self.emitPayloadHolder(operand);
                    try self.closeCatchSlot(own);
                    return self.w.print(") |*{s}| {s} else |__rig_failed| return __rig_failed)", .{ v, v });
                }
                const routed = self.routedOptional(self.typeOf(operand));
                try self.w.writeAll(if (routed) "(if (rig.somePtr(&" else "(if (");
                try self.emitPayloadHolder(operand);
                try self.w.print("{s} |{s}{s}| {s} else ", .{ if (routed) "))" else ")", if (routed) "" else "*", v, v });
                try self.writeReturnNone();
                return self.w.writeAll(")");
            },
            .jump => return self.emitExpr(e),
            .place, .part, .lend => {
                const saved = self.read_place;
                defer self.read_place = saved;
                self.read_place = true;
                return self.emitAddressOf(e);
            },
            .literal => {
                // An absent optional, whose payload no branch captures,
                // so nothing writes through its address.
                if (self.isNoneLeaf(e)) {
                    try self.w.writeAll("rig.noneAt(");
                    try self.emitTypeTy(ty);
                    return self.w.writeAll(")");
                }
                try self.zigTemporary(e);
                try self.w.writeAll("&");
                try self.writeAsOpen(ty);
                try self.emitBare(e);
                return self.w.writeAll(")");
            },
            .made => {
                // A value kept in its statement's slot is reached there.
                if (self.facts.dropsTemp(e)) {
                    try self.w.writeAll("&(");
                    try self.emitBare(e);
                    return self.w.writeAll(")");
                }
                try self.zigTemporary(e);
                try self.w.writeAll("&");
                try self.writeAsOpen(ty);
                try self.emitBare(e);
                return self.w.writeAll(")");
            },
        }
    }

    /// The optional type of `a ?? b` (`e`) whose fallback is a `T?` like
    /// `a`, so the value is one too, where it goes through the helpers;
    /// null for any other.
    fn optionalFallback(self: *Emitter, e: Sexp) ?TypeId {
        const result = self.typeOf(e) orelse return null;
        const inner = switch (self.facts.types.get(result)) {
            .optional => |inner| inner,
            else => return null,
        };
        if (!self.routesPayload(inner)) return null;
        const held = self.typeOf(ir.@"??".left(e)) orelse return null;
        // A payload copied out of the view it is gives the value it views
        // (`rig.copiedOut`, a Zig `?T`).
        if (self.facts.copiesPayload(e)) return if (self.facts.payloadViewed(held) == inner) result else null;
        return switch (self.facts.types.get(self.peelViews(held))) {
            .optional => |payload| if (payload == inner) result else null,
            else => null,
        };
    }

    /// The optional type of `a catch b` (`e`) whose handler is a `T?` and
    /// whose value succeeds with a `T`, which Zig would lift into it, where
    /// it goes through the helpers; null for any other.
    fn optionalHandler(self: *Emitter, e: Sexp) ?TypeId {
        const result = self.typeOf(e) orelse return null;
        const inner = switch (self.facts.types.get(result)) {
            .optional => |inner| inner,
            else => return null,
        };
        if (!self.routesPayload(inner)) return null;
        const held = self.typeOf(ir.Catch.value(e)) orelse return null;
        // A payload copied out of the view it is gives the value it views.
        if (self.facts.copiesPayload(e)) return if (self.facts.payloadViewed(held) == inner) result else null;
        return switch (self.facts.types.get(held)) {
            .fallible => |payload| if (payload.ok == inner) result else null,
            else => null,
        };
    }

    /// `return null` from the function being emitted, whose result is
    /// an optional: `none` packed into it where it goes through the
    /// helpers.
    fn writeReturnNone(self: *Emitter) Error!void {
        if (self.fun.return_ty) |r| {
            const o = self.unwrapFallible(r);
            if (self.facts.types.get(o) == .optional and self.routesPayload(self.facts.types.get(o).optional)) {
                try self.w.writeAll("return rig.pack(");
                try self.emitTypeTy(o);
                return self.w.writeAll(", null)");
            }
        }
        try self.w.writeAll("return null");
    }

    /// `holder`, the operand of `a ?? b` or `a catch b` (`form`): as it
    /// is, or, where the form copies the value its payload views out
    /// (`Facts.copiesPayload`), `rig.copiedOut(T, holder)`, which gives
    /// the payload the `T` its view holds or points at.
    fn emitFallbackHolder(self: *Emitter, form: Sexp, holder: Sexp) Error!void {
        if (!self.facts.copiesPayload(form)) return self.emitExpr(holder);
        const ty = self.typeOf(holder) orelse return self.unsupported(holder, "an untyped optional");
        const viewed = self.facts.payloadViewed(ty) orelse return self.unsupported(holder, "a payload copied out of no view");
        try self.w.writeAll("rig.copiedOut(");
        try self.emitTypeTy(viewed);
        try self.w.writeAll(", ");
        try self.emitExpr(holder);
        try self.w.writeAll(")");
    }

    /// The optional or fallible value `e`, whose payload a branch takes
    /// by address (`emitLeafPtr`), as an lvalue where it can be: a place
    /// where it is, so the payload captured by pointer is the place's
    /// own; a value that branches at the leaf it takes; a value its
    /// statement's slot keeps there.
    fn emitPayloadHolder(self: *Emitter, e: Sexp) Error!void {
        const ty = self.typeOf(e) orelse return self.unsupported(e, "an untyped optional");
        switch (self.facts.leafStep(e) orelse return self.unsupported(e, "a value reached by address that no checker walked")) {
            .@"if", .fallback, .unwrap, .place, .part, .literal => {
                try self.w.writeAll("(");
                try self.emitLeafPtr(e, ty);
                return self.w.writeAll(").*");
            },
            // The payload is captured by address where Zig holds it.
            .made => if (!self.facts.dropsTemp(e)) {
                try self.zigTemporary(e);
            },
            // A lend of an optional or fallible value whose payload is read
            // by address would hand over a resource or a value of a type
            // parameter from inside a view, which typecheck rejects: a
            // payload captured from a lend has no storage a fact names.
            .lend => return self.unsupported(e, "a payload captured by address from a lend"),
            .jump => {},
        }
        try self.emitBare(e);
    }

    /// `$builtin(args)`. Arguments that name Rig types are spelled as Zig
    /// types. A builtin call as Zig names it. `@fromBackingInt` takes the enum's
    /// backing integer type exactly, an unsigned one, so its operand, any
    /// integer, goes through `@intCast` (checked in safe builds, as the
    /// tag is; `openUnsignedCast`).
    fn emitBuiltin(self: *Emitter, sexp: Sexp) Error!void {
        if (std.mem.eql(u8, self.srcText(ir.Builtin.name(sexp)), "variants")) return self.emitVariants(sexp);
        if (std.mem.eql(u8, self.srcText(ir.Builtin.name(sexp)), "name")) return self.emitNameQuery(sexp);
        const name = zigBuiltinName(self.srcText(ir.Builtin.name(sexp)));
        const cast = std.mem.eql(u8, name, "fromBackingInt");
        try self.w.print("@{s}(", .{name});
        const args = ir.Builtin.args(sexp);
        const through = if (cast and args.len == 1) try self.openUnsignedCast(args[0], self.typeOf(args[0]), null) else false;
        if (cast and args.len != 1) try self.w.writeAll("@intCast(");
        for (args, 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (self.isTypeArg(sexp, a)) try self.emitTypeTy(self.typeOf(a).?) else try self.emitBare(a);
        }
        if (cast) try self.closeUnsignedCast(through);
        try self.w.writeAll(")");
    }

    /// `$variants(T)`: `[N]T{ T.a, T.b }`, the variants in order.
    fn emitVariants(self: *Emitter, sexp: Sexp) Error!void {
        const arr = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped `$variants`");
        const elem = switch (self.facts.types.get(arr)) {
            .array => |a| a.elem,
            else => return self.unsupported(sexp, "`$variants` of this type"),
        };
        const decl = self.facts.nominalDecl(elem) orelse return self.unsupported(sexp, "`$variants` of this type");
        try self.w.writeAll("(");
        try self.emitTypeTy(arr);
        try self.w.writeAll("{ ");
        var first = true;
        for (decl.symbol().fields orelse &.{}) |f| {
            if (!f.is_variant) continue;
            if (!first) try self.w.writeAll(", ");
            first = false;
            try self.emitTypeTy(elem);
            try self.w.print(".{f}", .{ident(f.name)});
        }
        try self.w.writeAll(" })");
    }

    /// `$name(T)`: the type's name as sema's printer spells it, the
    /// string itself for a type known here. A type that holds a type
    /// parameter is spelled per instance: the printer's spelling, with
    /// each parameter named by `rig.typeName` from the module's table
    /// (`emitNamesTable`). Zig's `@typeName`, inside `raw`, is Zig's.
    fn emitNameQuery(self: *Emitter, sexp: Sexp) Error!void {
        const arg = ir.Builtin.args(sexp)[0];
        const of = if (arg.isKind(.builtin)) ir.Builtin.args(arg)[0] else arg;
        const ty = self.typeOf(of) orelse return self.unsupported(arg, "an untyped `$name` argument");
        const spelling = try self.facts.formatTypeMarked(self.arena.allocator(), ty);
        // `$name($type(x))` reads `x`, as `$size($type(x))` does
        // (`@TypeOf(x)`), though its name is known: a binding read only
        // there is still used in the Zig.
        const of_value = arg.isKind(.builtin);
        if (of_value) {
            try self.w.writeAll("(blk: { _ = @TypeOf(");
            try self.emitBare(of);
            try self.w.writeAll("); break :blk ");
        }
        if (std.mem.findScalar(u8, spelling, facts.type_param_mark) == null) {
            try self.w.print("\"{s}\"", .{spelling});
        } else {
            self.uses_names = true;
            try self.w.writeAll("(comptime ");
            try self.writeSpelling(spelling, .concat, null);
            try self.w.writeAll(")");
        }
        if (of_value) try self.w.writeAll("; })");
    }

    /// A marked spelling (`sema.formatTypeMarked`) as Zig: its strings,
    /// and each type parameter as `how` writes it. `.concat` joins them
    /// with `++`, each parameter named by `rig.typeName`; `.parts` lists
    /// them in a tuple, each parameter as itself, or, given the generic
    /// type `of`, as its index among that type's parameters. A type
    /// marked whole (`t` and its id) is written as its Zig type, and named
    /// so in `.concat`.
    fn writeSpelling(self: *Emitter, spelling: []const u8, how: enum { concat, parts }, of: ?SymbolId) Error!void {
        if (how == .parts) try self.w.writeAll(".{ ");
        var it = std.mem.splitScalar(u8, spelling, facts.type_param_mark);
        var i: usize = 0;
        var first = true;
        while (it.next()) |piece| : (i += 1) {
            const is_param = i % 2 == 1;
            if (!is_param and piece.len == 0) continue;
            if (!first) try self.w.writeAll(if (how == .concat) " ++ " else ", ");
            first = false;
            if (!is_param) {
                try self.w.print("\"{s}\"", .{piece});
                continue;
            }
            // `List[T, inline: n]`'s length: `InlineList`'s second argument.
            if (std.mem.eql(u8, piece, "n")) {
                try self.w.writeAll("1");
                continue;
            }
            if (piece[0] == 't') {
                const ty = std.fmt.parseInt(TypeId, piece[1..], 10) catch unreachable;
                if (how == .concat) try self.w.writeAll("rig.typeName(");
                try self.emitTypeTy(ty);
                if (how == .concat) try self.w.writeAll(", __rig_names)");
                continue;
            }
            const sym = std.fmt.parseInt(SymbolId, piece, 10) catch unreachable;
            if (of) |generic| {
                const params = self.facts.symbols.items[generic].type_params.?;
                try self.w.print("{d}", .{std.mem.findScalar(SymbolId, params, sym).?});
            } else if (how == .concat) {
                try self.w.writeAll("rig.typeName(");
                try self.writeTypeParam(sym);
                try self.w.writeAll(", __rig_names)");
            } else try self.writeTypeParam(sym);
        }
        if (how == .parts) try self.w.writeAll(" }");
    }

    /// `const __rig_names = .{ ... };`: what `rig.typeName` needs to name
    /// a type parameter's instance as this module writes it, every name
    /// from sema's printer: this module (`nameModule`), what each module
    /// it imports qualifies its types with, each built-in type, and the
    /// spelling of each of the runtime's generic types.
    fn emitNamesTable(self: *Emitter) Error!void {
        const ctx = self.facts;
        const a = self.arena.allocator();
        try self.w.print("\nconst __rig_names = .{{\n    .module = \"{s}\",\n    .imports = .{{\n", .{nameModule(ctx)});
        for (0..ctx.importCount()) |i| {
            const imp = ctx.importAt(i);
            // The first import of a module names it, as in the printer.
            const seen = for (0..i) |j| {
                if (ctx.importAt(j).module_id == imp.module_id) break true;
            } else false;
            if (!seen) try self.w.print("        .{{ \"{s}\", \"{s}.\" }},\n", .{ imp.facts.name, imp.local_name });
        }
        try self.w.writeAll("    },\n    .types = .{\n");
        for (try ctx.builtinTypes(a)) |t| {
            // `Symbol` names itself (`rig.typeName`), so a module that
            // writes no symbol need not import them.
            if (t == .symbol) continue;
            try self.w.writeAll("        .{ ");
            // `error` is a `rig.ErrorValue` (an error of any set, with its
            // fields).
            if (t == .any_error) try self.w.writeAll("rig.ErrorValue") else try self.emitBuiltinTy(t);
            try self.w.print(", \"{s}\" }},\n", .{try ctx.formatTypeValue(a, t)});
        }
        for ([_]SymbolId{ ctx.endian_sym_id, ctx.arch_sym_id, ctx.order_sym_id, ctx.printer_sym_id, ctx.hasher_sym_id }) |sym| {
            try self.w.writeAll("        .{ ");
            try self.writeNominalName(sym);
            try self.w.print(", \"{s}\" }},\n", .{try ctx.formatTypeValue(a, .{ .nominal = sym })});
        }
        try self.w.writeAll("    },\n    .generics = .{\n");
        for (0..ctx.symbols.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            // A box is named as a handle is, from its shape (`rig.typeName`).
            if (!ctx.isBuiltinGeneric(sym) or sym == ctx.box_sym_id) continue;
            try self.w.writeAll("        .{ ");
            try self.writeNominalName(sym);
            try self.w.writeAll(", ");
            try self.writeSpelling(try ctx.formatGenericSelfMarked(a, sym), .parts, sym);
            try self.w.writeAll(" },\n");
            if (sym == ctx.list_sym_id) {
                try self.w.writeAll("        .{ rig.InlineList, ");
                try self.writeSpelling(try ctx.formatInlineListMarked(a), .parts, sym);
                try self.w.writeAll(" },\n");
            }
        }
        try self.w.writeAll("    },\n};\n");
    }

    /// The Zig name of builtin `name`: Rig's type queries are Zig's
    /// under their own names (`$size` is `@sizeOf`); every other builtin
    /// is Zig's, as written.
    fn zigBuiltinName(name: []const u8) []const u8 {
        const rig_names = std.StaticStringMap([]const u8).initComptime(.{
            .{ "size", "sizeOf" }, .{ "align", "alignOf" }, .{ "name", "typeName" }, .{ "type", "TypeOf" },
        });
        return rig_names.get(name) orelse name;
    }

    /// Every argument of `@sizeOf`, `@alignOf`, and `@typeName` is a
    /// type, except `@TypeOf(x)`.
    fn isTypeArg(self: *Emitter, builtin: Sexp, a: Sexp) bool {
        if (a.isKind(.builtin)) return false;
        const name = zigBuiltinName(self.srcText(ir.Builtin.name(builtin)));
        return std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf") or std.mem.eql(u8, name, "typeName");
    }

    /// `*expr`: move `expr` into a new reference-counted box.
    fn emitShare(self: *Emitter, sexp: Sexp) Error!void {
        const inner = ir.Share.operand(sexp);
        if (inner.isKind(.lambda)) return self.emitOwnedClosure(inner);
        // `*Actor(x)`, `*Actor(x, mailbox: n)`: the runtime makes the
        // actor behind its first handle.
        if (self.facts.isActorMake(inner)) {
            try self.w.writeAll("rig.actor(");
            try self.emitArgs(inner);
            if (ir.Call.args(inner).len == 1) try self.w.writeAll(", 64");
            return self.w.writeAll(")");
        }
        // `*Frozen(x)`: the runtime freezes `x` behind its first handle.
        if (self.facts.isFrozenMake(inner)) {
            const value = ir.Call.args(inner)[0];
            const payload = self.facts.frozenValue(self.typeOf(inner) orelse return self.unsupported(inner, "an untyped frozen value")).?;
            try self.w.writeAll("rig.frozen(");
            try self.writeAsOpen(payload);
            try self.emitBare(value);
            return self.w.writeAll("))");
        }
        // `*Chan[T](n)`: the runtime makes the channel behind its first
        // handle.
        if (self.facts.isChanMake(inner)) {
            const ty = self.typeOf(inner) orelse return self.unsupported(inner, "an untyped channel");
            try self.w.writeAll("rig.chan(");
            try self.emitTypeTy(self.facts.types.get(ty).parameterized_nominal.args[0]);
            try self.w.writeAll(", ");
            try self.emitArgs(inner);
            return self.w.writeAll(")");
        }
        // `*Actor.supervised(f, ...)`: the runtime makes the actor from
        // `f`, which it keeps, with each option or its default.
        if (self.facts.isActorSupervised(inner)) {
            const args = ir.Call.args(inner);
            try self.w.writeAll("rig.actorSupervised(");
            try self.emitExpr(args[0]);
            for ([_][]const u8{ "mailbox", "restarts", "per" }, [_][]const u8{ "64", "-1", "0" }) |name, default| {
                try self.w.writeAll(", ");
                const given = for (args[1..]) |a| {
                    if (std.mem.eql(u8, self.srcText(ir.Kwarg.name(a)), name)) break ir.Kwarg.value(a);
                } else null;
                if (given) |v| try self.emitExpr(v) else try self.w.writeAll(default);
            }
            return self.w.writeAll(")");
        }
        // `*w` upgrading a weak handle: the runtime's `upgrade`, called on
        // a handle it reads where it stands; one it takes is dropped once
        // upgraded.
        if (self.facts.upgradeOf(sexp)) |how| switch (how) {
            .reads => {
                try self.emitMemberBase(inner, self.typeOf(inner));
                return self.w.writeAll(".upgrade()");
            },
            .takes => {
                try self.w.writeAll("rig.upgradeTaken(");
                try self.emitBare(inner);
                return self.w.writeAll(")");
            },
        };
        const payload_ty: ?TypeId = if (self.typeOf(sexp)) |t| switch (self.facts.types.get(t)) {
            .shared => |p| p,
            else => null,
        } else null;
        try self.w.writeAll("rig.shared(");
        // A constructor call spells its own type: `rig.shared(Node{ ... })`.
        const typed = payload_ty != null and self.isConstructorCall(inner) and
            if (self.typeOf(inner)) |inner_ty| inner_ty == payload_ty.? else false;
        const cast = payload_ty != null and !typed;
        if (cast) try self.writeAsOpen(payload_ty.?);
        try self.emitBare(inner);
        try self.w.writeAll(if (cast) "))" else ")");
    }

    // -------------------------------------------------------------------------
    // Value-position blocks and branches
    // -------------------------------------------------------------------------

    /// `(if cond then else)` as a value.
    fn emitIfExpr(self: *Emitter, sexp: Sexp) Error!void {
        return self.emitIfYieldAs(sexp, .value, self.typeOf(sexp));
    }

    /// `(if cond then else)` yielding `how` each branch's value, of type
    /// `result`: the `if`'s own, or for a leaf reached by address, the
    /// type of the value it is a leaf of (a branch of `none`s alone has
    /// no optional type of its own).
    fn emitIfYieldAs(self: *Emitter, sexp: Sexp, how: Yield, result: ?TypeId) Error!void {
        const cond = ir.If.cond(sexp);
        const else_ = ir.If.@"else"(sexp);
        if (else_ == .nil) return self.unsupported(sexp, "an `if` without `else` in value position");
        if (try self.hasAsMatch(cond)) {
            // A labeled block: the parts break out with the then-value;
            // falling through, the `else` value (`emitChain`).
            const label = try self.fmt("__rig_if_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
            try self.openBrace();
            try self.pushScope();
            const End = struct {
                sexp: Sexp,
                label: []const u8,
                result: ?TypeId,
                how: Yield,
                fn run(c: *const @This(), e: *Emitter) Error!void {
                    try e.writeIndent(e.indent);
                    try e.w.print("break :{s} ", .{c.label});
                    try e.emitYieldBlock(ir.If.then(c.sexp), .{}, c.result, c.how);
                    try e.w.writeAll(";\n");
                }
            };
            const end: End = .{ .sexp = sexp, .label = label, .result = result, .how = how };
            try self.emitChain(try self.conditionParts(cond), 0, &end, null);
            try self.popScope();
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{label});
            try self.emitYieldBlock(else_, .{}, result, how);
            try self.w.writeAll(";\n");
            return self.closeBrace();
        }
        if (rig.isConditionJoin(cond)) {
            // A labeled block: the nested `if`s of the parts break out
            // with the then-value; falling through, the `else` value.
            const parts = try self.conditionParts(cond);
            const label = try self.fmt("__rig_if_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
            try self.openBrace();
            try self.writeIndent(self.indent);
            try self.pushScope();
            try self.openParts(parts);
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{label});
            try self.emitYieldBlock(ir.If.then(sexp), .{}, result, how);
            try self.w.writeAll(";\n");
            try self.closeParts(parts.len, null);
            try self.popScope();
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} ", .{label});
            try self.emitYieldBlock(else_, .{}, result, how);
            try self.w.writeAll(";\n");
            return self.closeBrace();
        }
        try self.w.writeAll("if ");
        try self.pushScope();
        const prelude = try self.emitCond(cond);
        try self.emitYieldBlock(ir.If.then(sexp), prelude, result, how);
        try self.popScope();
        try self.w.writeAll(" else ");
        try self.emitYieldBlock(else_, .{}, result, how);
    }

    /// A block that yields its last expression: inline when it is a
    /// single expression, otherwise a labeled block. The value leaves the
    /// block, so a resource binding in tail position is moved out. A block
    /// ending in `return`/`break`/`continue` yields nothing and needs no
    /// label. `result` is the type the block yields.
    fn emitValueBlock(self: *Emitter, body: Sexp, prelude: Prelude, result: ?TypeId) Error!void {
        return self.emitYieldBlock(body, prelude, result, .value);
    }

    /// A block that yields its last expression `how`: the value, or the
    /// address of the leaf it is (`emitLeafPtr`).
    fn emitYieldBlock(self: *Emitter, body: Sexp, prelude: Prelude, result: ?TypeId, how: Yield) Error!void {
        const stmts = try self.stmtsOf(body);
        if (stmts.len == 0) return self.unsupported(body, "an empty block in value position");
        const last = stmts[stmts.len - 1];
        if (stmts.len == 1 and prelude.isEmpty() and self.yieldsValue(last) and !self.hasTemps(last) and !try self.hasErasedCopies(last)) return self.emitYield(last, result, how);

        const terminates = isTerminatingStmt(last);
        // A block whose value is Void may end in a statement that gives
        // none, as a `catch` handler after a call that gives nothing
        // does: it breaks out with `{}`.
        if (!terminates and !self.yieldsValue(last) and result == self.facts.types.void_id and how == .value) {
            const label = try self.fmt("__rig_blk_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
            try self.openBrace();
            try self.emitPrelude(prelude);
            try self.emitStmts(stmts);
            try self.writeIndent(self.indent);
            try self.w.print("break :{s} {{}};\n", .{label});
            return self.closeBrace();
        }
        if (!terminates and !self.yieldsValue(last)) return self.unsupported(last, "a block without a value in value position");
        var label: []const u8 = "";
        if (!terminates) {
            label = try self.fmt("__rig_blk_{d}", .{self.nextId()});
            try self.w.print("{s}: ", .{label});
        }
        try self.openBrace();
        try self.emitPrelude(prelude);
        try self.emitStmts(stmts[0 .. stmts.len - 1]);
        try self.writeIndent(self.indent);
        if (terminates) {
            try self.emitStmt(last);
        } else {
            const first = self.temp_slots.items.len;
            defer self.temp_slots.shrinkRetainingCapacity(first);
            const erased = self.erased_slots.items.len;
            defer self.erased_slots.shrinkRetainingCapacity(erased);
            try self.emitErasedSlots(last);
            try self.emitTempSlots(last);
            try self.w.print("break :{s} ", .{label});
            self.bare = true;
            try self.emitYield(last, result, how);
            try self.w.writeAll(";");
        }
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// `e`, a branch's value, yielded `how`.
    fn emitYield(self: *Emitter, e: Sexp, result: ?TypeId, how: Yield) Error!void {
        switch (how) {
            .value => return self.emitValueAs(e, result),
            .leaf_ptr => {
                self.bare = false;
                return self.emitLeafPtr(e, result orelse return self.unsupported(e, "an untyped branch"));
            },
        }
    }

    // -------------------------------------------------------------------------
    // Calls
    // -------------------------------------------------------------------------

    /// Whether `call` calls the built-in `swap`.
    fn isSwapCall(self: *Emitter, call: Sexp) bool {
        const callee = self.facts.calleeOf(call);
        if (callee != .src or self.facts.symbolOf(callee) != null) return false;
        return std.mem.eql(u8, self.srcText(callee), "swap");
    }

    /// `rig.swapPlaces(&a, &b)` / `rig.swapValue(&place, value)`: each
    /// place by its address, a held write view as the pointer it is
    /// (`sema.swapsTwoPlaces`).
    fn emitSwapCall(self: *Emitter, args: []const Sexp) Error!void {
        const two = args.len == 2 and self.facts.swapsTwoPlaces(args[1]);
        try self.w.writeAll(if (two) "rig.swapPlaces(" else "rig.swapValue(");
        for (args, 0..) |a, i| {
            if (i > 0) try self.w.writeAll(", ");
            if (i == 0 or two) {
                if (!try self.emitHeldAddress(a)) try self.emitAddressOf(lentPlace(a));
            } else try self.emitStored(a);
        }
        try self.w.writeAll(")");
    }

    /// How a value of type `ty` (viewed or not) reaches the String it
    /// views: directly, or through a `^String`; null for anything else.
    fn stringReach(self: *Emitter, ty: TypeId) ?[]const u8 {
        var t = self.peelViews(ty);
        var reach: []const u8 = "";
        while (t != self.facts.types.string_id) {
            const boxed = self.facts.types.get(t) != .shared;
            var held_view = false;
            t = switch (self.facts.types.get(t)) {
                .shared => |inner| self.peelViews(inner),
                else => blk: {
                    const inner = self.facts.boxedType(t) orelse return null;
                    held_view = self.isPtrViewTy(inner);
                    break :blk self.peelViews(inner);
                },
            };
            // A box's value is behind a pointer; a view it holds, or a
            // handle it holds, is one more, which Zig does not follow by
            // itself.
            const deref = boxed and (held_view or self.facts.types.get(t) == .shared);
            reach = self.fmt("{s}.value{s}", .{ reach, if (deref) ".*" else "" }) catch return null;
        }
        return reach;
    }

    /// `storage.stringCall`.
    fn stringCall(self: *Emitter, call: Sexp) ?facts.StringCall {
        return self.facts.stringCall(call);
    }

    /// `String(a, b)` → `rig.String.of(.{ a, &b })`; `!t.add(a, b)` →
    /// `t.add(.{ a, &b })`, the arguments written as `print`'s are
    /// (`emitPrintArgs`), so a place is read at the call; `!t.clear()` →
    /// `t.clear()`; `!t.reserve(n)` → `t.reserve(n)`; `!t.push[T, e](v)` →
    /// `t.pushInt(T, v, e)`; `!t.push(v, keep: k)` and `!t.push[T, e](v,
    /// keep: k)` → `t.pushKeep(T, v, k, e)`.
    fn emitStringCall(self: *Emitter, call: Sexp, op: facts.StringCall) Error!void {
        const args = ir.Call.args(call);
        switch (op) {
            .new => try self.w.writeAll("rig.String.of("),
            // `out.value(x)`, which the runtime writes as `print` writes a
            // part of another value (`rig.Printer.value`).
            .printer_value, .hasher_add => {
                const recv = ir.Member.object(self.facts.calleeOf(call));
                try self.emitMemberBase(recv, self.typeOf(recv));
                try self.w.writeAll(if (op == .hasher_add) ".add(" else ".value(");
                try self.emitExpr(args[0]);
                return self.w.writeAll(")");
            },
            .add, .push, .push_int, .push_keep, .reserve, .clear => {
                const recv = ir.Member.object(self.facts.calleeOf(call));
                try self.emitMemberBase(recv, self.typeOf(recv));
                if (self.typeOf(recv)) |t| try self.writeReach(t);
                if (op == .clear) return self.w.writeAll(".clear()");
                if (op == .push or op == .reserve) {
                    try self.w.print(".{s}(", .{@tagName(op)});
                    try self.emitBare(args[0]);
                    return self.w.writeAll(")");
                }
                // `.pushInt(T, v, endian)`; a one-byte `T` takes `.little`.
                if (op == .push_int) {
                    try self.w.writeAll(".pushInt(");
                    try self.emitTypeTy(self.facts.stringNumOf(self.facts.calleeOf(call)) orelse return self.unsupported(call, "a `push` without its type"));
                    try self.w.writeAll(", ");
                    try self.emitBare(args[0]);
                    try self.w.writeAll(", ");
                    const given = self.facts.ctArgsOf(call);
                    if (given.len == 2) try self.emitBare(given[1]) else try self.w.writeAll("rig.Endian.little");
                    return self.w.writeAll(")");
                }
                // `.pushKeep(T, v, k, endian)`: all of `v` is stored, the
                // first `k` bytes kept. A vector takes no byte order.
                if (op == .push_keep) {
                    const num = self.facts.stringNumOf(self.facts.calleeOf(call)) orelse return self.unsupported(call, "a `push` without its type");
                    try self.w.writeAll(".pushKeep(");
                    try self.emitTypeTy(num);
                    try self.w.writeAll(", ");
                    try self.emitBare(args[0]);
                    try self.w.writeAll(", ");
                    try self.emitBare(ir.Kwarg.value(args[1]));
                    try self.w.writeAll(", ");
                    const given = self.facts.ctArgsOf(call);
                    if (given.len == 2) try self.emitBare(given[1]) else try self.w.writeAll("rig.Endian.little");
                    return self.w.writeAll(")");
                }
                try self.w.writeAll(".add(");
            },
        }
        try self.emitPrintArgs(args, .{});
        try self.w.writeAll(")");
    }

    /// `storage.isPrintCall`.
    fn isPrintCall(self: *Emitter, call: Sexp) bool {
        return self.facts.isPrintCall(call);
    }

    /// A built-in element method: `!dst.copy(src)` is `rig.copy(dst,
    /// src)`, `fill` and `swap` likewise, and `read` and `write` are
    /// `rig.readInt` and `rig.writeInt`, on the receiver's elements
    /// (`emitElems`). The arguments are plain data, so none is hoisted.
    fn emitElemCall(self: *Emitter, call: Sexp, ec: facts.ElemCall) Error!void {
        try self.inUnit(call);
        const callee = self.facts.calleeOf(call);
        const args = ir.Call.args(call);
        switch (ec.op) {
            // `rig.readInt(T, bytes, at, endian)`,
            // `rig.writeInt(T, bytes, at, value, endian)`, and for a vector
            // `rig.simdRead` and `rig.simdWrite`, whose one-byte lanes need
            // no byte order.
            .read, .write => {
                const vector = self.facts.types.get(ec.num) == .simd;
                // A test known to pass is omitted (`provenOf`).
                const proven = provenTests(self.provenOf(callee));
                const read = ec.op == .read;
                try self.w.writeAll(if (vector) (if (proven != null)
                    (if (read) "rig.simdReadProven(" else "rig.simdWriteProven(")
                else if (read) "rig.simdRead(" else "rig.simdWrite(") else if (proven != null)
                    (if (read) "rig.readIntProven(" else "rig.writeIntProven(")
                else if (read) "rig.readInt(" else "rig.writeInt(");
                try self.emitTypeTy(ec.num);
                try self.w.writeAll(", ");
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
                try self.w.writeAll(", ");
                const given = self.facts.ctArgsOf(call);
                if (given.len == 2) try self.emitBare(given[1]) else try self.w.writeAll("rig.Endian.little");
                if (proven) |p| try self.w.print(", .{s}", .{p});
            },
            // `rig.rt(@as(V, @splat(x)))`.
            .splat => {
                try self.writeVectorOpen(ec.num);
                try self.w.writeAll("@splat(");
                try self.emitBare(args[0]);
                return self.w.writeAll(")))");
            },
            // `rig.maskBits(m)`, `rig.maskFirst(m)`, `rig.maskAny(m)`,
            // `rig.maskAll(m)`: the runtime lowers each per target.
            .bits, .first, .any, .all => {
                // `m.not().bits()` is `rig.maskBitsNot(m)`: NEON flips
                // the bits after the reduction, where flipping the lanes
                // first costs a vector instruction per 16 lanes.
                const obj = ir.Member.object(callee);
                if (ec.op == .bits and obj.isKind(.call)) if (self.facts.elemCallOf(self.facts.calleeOf(obj))) |inner| if (inner.op == .not) {
                    try self.w.writeAll("rig.maskBitsNot(");
                    try self.emitBare(ir.Member.object(self.facts.calleeOf(obj)));
                    return self.w.writeAll(")");
                };
                try self.w.writeAll(switch (ec.op) {
                    .bits => "rig.maskBits(",
                    .first => "rig.maskFirst(",
                    .any => "rig.maskAny(",
                    else => "rig.maskAll(",
                });
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll(")");
            },
            // `rig.maskSelect(m, a, b)`.
            .select => {
                try self.w.writeAll("rig.maskSelect(");
                try self.emitBare(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
                return self.w.writeAll(")");
            },
            // `@as([n]T, v)`, or `rig.maskArray(m)`.
            .array => {
                if (ec.elem == self.facts.types.bool_id) {
                    try self.w.writeAll("rig.maskArray(");
                    try self.emitBare(ir.Member.object(callee));
                    return self.w.writeAll(")");
                }
                try self.w.writeAll("@as([");
                try self.emitTypeTy(self.facts.types.get(ec.num).simd.len);
                try self.w.writeAll("]");
                try self.emitTypeTy(ec.elem);
                try self.w.writeAll(", ");
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll(")");
            },
            // `rig.lookup(t, idx)`, lowered per target by the runtime.
            .lookup => {
                try self.w.writeAll("rig.lookup(");
                try self.emitBare(ir.Member.object(callee));
                try self.w.writeAll(", ");
                try self.emitBare(args[0]);
                return self.w.writeAll(")");
            },
            // `rig.lag(k, cur, prev)`: one constant shuffle.
            .lag => {
                try self.w.writeAll("rig.lag(");
                try self.emitBare(self.facts.ctArgsOf(call)[0]);
                try self.w.writeAll(", ");
                try self.emitBare(ir.Member.object(callee));
                try self.w.writeAll(", ");
                try self.emitBare(args[0]);
                return self.w.writeAll(")");
            },
            // `rig.withLane(v, i, x)`.
            .with => {
                try self.w.writeAll("rig.withLane(");
                try self.emitBare(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    try self.emitBare(a);
                }
                return self.w.writeAll(")");
            },
            // `(~x)`, or `(!x)` of a Bool.
            .not => {
                const obj = ir.Member.object(callee);
                const lanes = switch (self.facts.types.get(self.peelViews(ec.num))) {
                    .simd => |v| v.elem,
                    else => self.peelViews(ec.num),
                };
                if (lanes == self.facts.types.bool_id and lanes != self.peelViews(ec.num)) {
                    try self.w.writeAll("rig.maskNot(");
                    try self.emitBare(obj);
                    return self.w.writeAll(")");
                }
                if (lanes == self.facts.types.bool_id) {
                    try self.w.writeAll("(!");
                    try self.emitExpr(obj);
                    return self.w.writeAll(")");
                }
                // In the receiver's type, so that a literal is typed.
                try self.w.writeAll("(~");
                try self.writeAsOpen(ec.num);
                try self.emitBare(obj);
                return self.w.writeAll("))");
            },
            // `@as(Int, @clz(x))`: the builtin counts in the receiver's
            // type, a bit pattern for a signed one, and gives a smaller
            // unsigned integer, which widens to `Int`.
            .leading_zeros, .trailing_zeros, .count_ones => {
                try self.writeAsOpen(ec.elem);
                try self.w.writeAll(switch (ec.op) {
                    .leading_zeros => "@clz(",
                    .trailing_zeros => "@ctz(",
                    else => "@popCount(",
                });
                try self.writeAsOpen(ec.num);
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll(")))");
            },
            // `@as(u64, @bitCast(x))`.
            .to_bits => {
                try self.writeAsOpen(ec.elem);
                try self.w.writeAll("@bitCast(");
                try self.writeAsOpen(ec.num);
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll(")))");
            },
            // `@as(f64, @bitCast(@as(u64, u)))`.
            .from_bits => {
                try self.writeAsOpen(ec.num);
                try self.w.writeAll("@bitCast(");
                try self.writeAsOpen(ec.elem);
                try self.emitBare(args[0]);
                return self.w.writeAll(")))");
            },
            // `std.math.nan(f64)`, `std.math.inf(f64)`.
            .nan, .inf => {
                try self.w.print("std.math.{s}(", .{@tagName(ec.op)});
                try self.emitTypeTy(ec.num);
                return self.w.writeAll(")");
            },
            // `rig.frexpFraction(x)`, `rig.frexpExponent(x)`.
            .fraction, .exponent => {
                try self.w.print("rig.frexp{s}(", .{if (ec.op == .fraction) "Fraction" else "Exponent"});
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll(")");
            },
            // The low bits, read in the target's signedness.
            .wrap => return self.emitWrap(args[0], ec),
            // `rig.enumFromText(E, E.__rig_text, word)`: `word` found in
            // the table of `E`'s names (`emitTextTable`).
            .from_text => {
                // `__rig_sym.fromText(word)`: a symbol the program writes.
                if (ec.num == self.facts.types.symbol_id) {
                    self.uses_symbols = true;
                    try self.w.writeAll("__rig_sym.fromText(");
                    try self.emitArgs(call);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll("rig.enumFromText(");
                try self.emitTypeTy(ec.num);
                try self.w.writeAll(", ");
                try self.writeTextTable(ec.num);
                try self.w.writeAll(", ");
                try self.emitArgs(call);
                return self.w.writeAll(")");
            },
            // `rig.slotOf(n, i)`: `Slot[n].of(i)`.
            .from_int => if (self.facts.types.get(ec.num) == .slot) {
                try self.w.writeAll("rig.slotOf(");
                try self.emitTypeTy(self.facts.types.get(ec.num).slot);
                try self.w.writeAll(", ");
                try self.emitBare(args[0]);
                return self.w.writeAll(")");
            } else {
                try self.w.writeAll("rig.enumFromInt(");
                try self.emitTypeTy(ec.num);
                try self.w.writeAll(", ");
                try self.writeAsOpen(ec.elem);
                try self.emitBare(args[0]);
                return self.w.writeAll("))");
            },
            // `rig.sum(elems, start)`, `0` when none is given.
            .sum => {
                try self.w.writeAll("rig.sum(");
                try self.emitElems(ir.Member.object(callee));
                try self.w.writeAll(", ");
                if (args.len == 1) try self.emitBare(ir.get(args[0], .value)) else try self.w.writeAll("0");
                return self.w.writeAll(")");
            },
            // `rig.orderOf(a, b)`: an `Order` (`Checker.orderCall`).
            .order => {
                try self.w.writeAll("rig.orderOf(");
                try self.emitExpr(ir.Member.object(callee));
                try self.w.writeAll(", ");
                try self.emitExpr(if (args[0].isKind(.kwarg)) ir.Kwarg.value(args[0]) else args[0]);
                return self.w.writeAll(")");
            },
            // `rig.hash(x)`, of the value the receiver reaches.
            .hash => {
                try self.w.writeAll("rig.hash(");
                try self.emitExpr(ir.Member.object(callee));
                return self.w.writeAll(")");
            },
            .swap_bytes => {
                try self.w.writeAll("@byteSwap(");
                try self.writeAsOpen(ec.num);
                try self.emitBare(ir.Member.object(callee));
                return self.w.writeAll("))");
            },
            .copy, .fill, .swap => {
                try self.w.print("rig.{s}(", .{@tagName(ec.op)});
                try self.emitElems(ir.Member.object(callee));
                for (args) |a| {
                    try self.w.writeAll(", ");
                    if (self.facts.lendsTempArray(a)) {
                        try self.zigTemporary(a);
                        try self.w.writeAll("&");
                    }
                    try self.emitBare(a);
                }
            },
        }
        try self.w.writeAll(")");
    }

    /// `I32.wrap(x)`: to a narrower target, truncate the source's bits;
    /// to a wider one, widen at the source's signedness; then read the
    /// bits as the target.
    fn emitWrap(self: *Emitter, arg: Sexp, ec: facts.ElemCall) Error!void {
        const from = self.facts.types.get(ec.elem).int;
        const to = self.facts.types.get(ec.num).int;
        const wf = from.width();
        const wt = to.width();
        try self.writeAsOpen(ec.num);
        try self.w.writeAll("@bitCast(");
        if (wt < wf) {
            try self.w.print("@as(u{d}, @truncate(@as(u{d}, @bitCast(", .{ wt, wf });
            try self.writeAsOpen(ec.elem);
            try self.emitBare(arg);
            return self.w.writeAll(")))))))");
        }
        if (wt == wf) {
            try self.writeAsOpen(ec.elem);
            try self.emitBare(arg);
            return self.w.writeAll(")))");
        }
        try self.w.print("@as({c}{d}, @intCast(", .{ @as(u8, if (from.signed) 'i' else 'u'), wt });
        try self.writeAsOpen(ec.elem);
        try self.emitBare(arg);
        try self.w.writeAll(")))))");
    }

    /// `rig.rt(@as(V, `, which a vector's construction closes with `))`
    /// after its value.
    /// Every vector a program makes comes from a construction (`splat`,
    /// `Simd[T, n](a)`, a scalar splatted beside a vector), a parameter,
    /// or bytes read when the program runs, and a module constant that
    /// holds one is a Zig `var` (`emitConst`); so
    /// with each construction a run-time value, no vector is known to Zig
    /// when it compiles, and a lane that overflows panics when the program
    /// runs, as Rig specifies, rather than stopping Zig's fold.
    fn writeVectorOpen(self: *Emitter, vt: TypeId) Error!void {
        try self.w.writeAll(if (self.isMask(vt)) "rig.rt(rig.maskOf(" else "rig.rt(@as(");
        try self.emitTypeTy(vt);
        try self.w.writeAll(", ");
    }

    /// The vector type a call of a vector type makes, `Simd[T, n](a)`,
    /// or `Block(a)` and `lib.Block(a)` for an alias of one; null for any
    /// other call.
    fn simdConversion(self: *Emitter, call: Sexp) ?TypeId {
        const ty = self.typeOf(call) orelse return null;
        if (self.facts.types.get(ty) != .simd) return null;
        const callee = ir.Call.callee(call);
        if (self.facts.isTypeCallee(callee)) return ty;
        const id = self.facts.symbolOf(callee) orelse return null;
        return if (self.facts.symbols.items[id].kind == .type_alias) ty else null;
    }

    /// The elements of a method's receiver (a slice, an array, a List, or
    /// a `?String`, viewed or not) as a Zig slice or array pointer: a
    /// slice or `?String` as it is, an array through its address (writable
    /// when the receiver is written `!xs`), a List through its items.
    fn emitElems(self: *Emitter, recv: Sexp) Error!void {
        const writes = recv.isKind(.write);
        const place = if (recv.isKind(.write) or recv.isKind(.read)) ir.get(recv, .operand) else recv;
        const ty = self.peelViews(self.typeOf(place) orelse return self.unsupported(recv, "an untyped `self`"));
        if (self.isListTy(ty)) {
            try self.emitExpr(place);
            return self.w.writeAll(".items()");
        }
        if (self.facts.types.get(ty) == .array) {
            const saved_read = self.read_place;
            defer self.read_place = saved_read;
            self.read_place = !writes;
            return self.emitAddressOf(place);
        }
        // A String lent to read, `(?s).read[...]`, lends its bytes.
        if (self.stringReach(ty)) |reach| {
            try self.emitBaseExpr(place);
            return self.w.print("{s}.bytes()", .{reach});
        }
        try self.emitBare(place);
    }

    /// A call. One that may reach an inlined function is read through
    /// `rig.rt`: Zig analyzes that body at the call, where a result that
    /// does not depend on the arguments is known at compile time, as is a
    /// `const` bound to it, so arithmetic on it would be folded where Rig
    /// specifies a check when the program runs. `rig.rt` keeps the
    /// whole result, error or optional included, a run-time value.
    fn emitCallDirect(self: *Emitter, sexp: Sexp) Error!void {
        if (ir.Call.task(sexp) != .nil) return self.emitTask(sexp);
        if (!self.facts.callsInlined(sexp)) return self.emitCallPlain(sexp);
        try self.w.writeAll("rig.rt(");
        try self.emitCallPlain(sexp);
        try self.w.writeAll(")");
    }

    /// `f(x)&`: the call started as a task, its arguments evaluated here
    /// (`rig.Task(T).spawn`). A method's receiver goes by its address,
    /// which the runtime passes on, or reads when the method takes its
    /// receiver by value (`spawnMethod`).
    fn emitTask(self: *Emitter, sexp: Sexp) Error!void {
        const callee = self.facts.calleeOf(sexp);
        // `c.m(x)&` through an actor's handle (`rig.actorSpawn`).
        if (self.facts.isActorCall(sexp)) {
            const obj = ir.Member.object(callee);
            try self.w.writeAll("rig.actorSpawn(");
            try self.emitMemberBase(obj, self.typeOf(obj) orelse return self.unsupported(obj, "an untyped actor handle"));
            try self.w.print(", \"{s}\", .{{ ", .{self.srcText(ir.Member.name(callee))});
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        }
        try self.emitTypeTy(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped task"));
        // Through a witness: its method, given self as it takes it.
        if (self.facts.dispatchOf(sexp)) |d| if (d == .static and !d.static.receiver_arg and d.static.self_mode != .value) {
            const recv = self.receiverOf(sexp) orelse return self.unsupported(sexp, "a call through a witness without its receiver");
            try self.w.writeAll(if (self.facts.isLocalTask(sexp)) ".spawnWitnessLocal(" else ".spawnWitness(");
            try self.writeWitnessMethod(d.static);
            try self.w.writeAll(", ");
            try self.emitReceiverAddress(recv, d.static);
            try self.w.writeAll(", .{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };
        // Through an API object whose braces let it go to the task: its
        // table's entry, given the address the object holds.
        if (self.facts.dispatchOf(sexp)) |d| if (d == .dynamic) {
            const recv = if (d.dynamic.receiver_arg) ir.Call.args(sexp)[0] else self.receiverOf(sexp) orelse return self.unsupported(sexp, "a call through an API object without its receiver");
            try self.w.writeAll(if (self.facts.isLocalTask(sexp)) ".spawnObjectLocal(" else ".spawnObject(");
            try self.emitExpr(lentPlace(recv));
            try self.w.print(", \"{s}\", .{{ ", .{d.dynamic.method});
            try self.emitArgsFrom(sexp, @intFromBool(d.dynamic.receiver_arg));
            return self.w.writeAll(" })");
        };
        if (self.facts.dispatchOf(sexp)) |d| if (d == .static) {
            try self.w.writeAll(if (self.facts.isLocalTask(sexp)) ".spawnLocal(" else ".spawn(");
            try self.writeWitnessMethod(d.static);
            try self.w.writeAll(", .{ ");
            if (!d.static.receiver_arg) {
                try self.emitExpr(self.receiverOf(sexp) orelse return self.unsupported(sexp, "a call through a witness without its receiver"));
                if (ir.Call.args(sexp).len > 0) try self.w.writeAll(", ");
            }
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };
        if (self.receiverOf(sexp)) |recv| {
            const saved = self.read_place;
            defer self.read_place = saved;
            self.read_place = !self.receiverWrites(sexp);
            try self.w.writeAll(if (self.facts.isLocalTask(sexp)) ".spawnMethodLocal(" else ".spawnMethod(");
            try self.emitAddressOf(lentPlace(recv));
            try self.w.print(", \"{s}\", .{{ ", .{self.srcText(ir.Member.name(callee))});
        } else {
            try self.w.writeAll(if (self.facts.isLocalTask(sexp)) ".spawnLocal(" else ".spawn(");
            try self.emitExpr(callee);
            try self.w.writeAll(", .{ ");
        }
        try self.emitArgs(sexp);
        try self.w.writeAll(" })");
    }

    fn emitCallPlain(self: *Emitter, sexp: Sexp) Error!void {
        const callee = self.facts.calleeOf(sexp);
        const args = ir.Call.args(sexp);

        if (self.facts.printCall(sexp)) |which| return switch (which) {
            .print => self.emitPrint(args),
            .warn => self.emitWarn(args),
        };
        if (self.stringCall(sexp)) |op| return self.emitStringCall(sexp, op);
        if (self.isSwapCall(sexp)) return self.emitSwapCall(args);
        if (callee == .src and self.facts.symbolOf(callee) == null and facts.syntax.isNumericTypeName(self.srcText(callee))) return self.emitConversion(sexp);
        // A call through an alias: a conversion to the number type it
        // names, or a value of the struct it names.
        if (self.isAliasCallee(callee)) {
            const t = self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped call through an alias");
            if (self.facts.isNumeric(t)) return self.emitConversion(sexp);
            if (self.facts.types.get(t) == .parameterized_nominal) {
                const g = self.facts.types.get(t).parameterized_nominal.sym;
                if (g == self.facts.list_sym_id) return self.emitListConstruction(sexp);
                if (g == self.facts.signal_sym_id) {
                    try self.emitTypeTy(t);
                    return self.emitSignalConstruction(sexp);
                }
            }
            try self.emitTypeTy(t);
            return self.emitFieldInit(args, self.declFields(t));
        }
        if (callee.isKind(.enum_lit)) return self.emitVariantLit(sexp);
        if (callee.isKind(.lambda)) return self.emitInlineInvoke(sexp);
        // A call through an API reaches its method through the witness,
        // or through an API object's table.
        if (self.facts.dispatchOf(sexp)) |d| switch (d) {
            .static => |st| return self.emitWitnessCall(sexp, st),
            .dynamic => |dy| return self.emitObjectCall(sexp, dy),
            .direct => {},
        };

        if (callee == .src) {
            if (self.localOf(callee)) |local| if (local.stack_closure) {
                try self.w.print("{s}.__rig_invoke(", .{local.zig_name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            };
            if (self.facts.symbolOf(callee)) |sym_id| {
                if (sym_id == self.facts.list_sym_id) return self.emitListConstruction(sexp);
                if (sym_id == self.facts.table_sym_id) return self.emitTableConstruction(sexp);
                if (sym_id == self.facts.signal_sym_id) return self.emitSignalConstruction(sexp);
                if (self.isTypeSym(sym_id)) return self.emitConstructor(sexp, sym_id);
            }
        }
        // A member callee without a type of its own names a variant
        // through its enum (`Shape.circle(r: 2)`, `m.Shape.circle(r: 2)`)
        // or a type in another module (`m.Type(field: v)`).
        if (callee.isKind(.member) and self.facts.typeOf(callee) == null) if (self.typeOf(sexp)) |t| {
            const vname = self.srcText(ir.Member.name(callee));
            if (self.isErrorSetTy(t) and self.variantPayload(t, vname) != null) return self.emitErrorMember(sexp, t, vname);
            if (self.variantPayload(t, vname) != null) {
                try self.writeAsOpen(t);
                try self.emitVariantPayload(sexp, t, vname);
                return self.w.writeAll(")");
            }
            if (self.facts.types.get(t) == .imported_nominal) {
                try self.emitMember(callee);
                return self.emitFieldInit(args, self.declFields(t));
            }
            // `m.Wrap[Int](v: 3)`, `m.Wrap(v: 3)`: the instance sema gave it.
            if (self.facts.types.get(t) == .parameterized_nominal and self.isTypeCallee(callee)) {
                try self.emitTypeTy(t);
                return self.emitFieldInit(args, self.declFields(t));
            }
        };
        // A callable view calls through its `rig.FnRef`.
        if (self.typeOf(callee)) |t| if (self.facts.callableFn(t) != null) {
            try self.emitExpr(callee);
            try self.w.writeAll(".call(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };
        // An owned closure handle, held by a name or a field, or a call
        // yielding a view of one, held by pointer.
        if (self.typeOf(callee)) |t| if (self.facts.ownedClosureFn(t) != null) {
            try self.emitExpr(callee);
            if (callee.isKind(.call) and self.isPtrViewTy(t)) try self.w.writeAll(".*");
            try self.w.writeAll(".value.invoke(.{ ");
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        };

        // `x.is_empty()` of a built-in length is `x.len == 0`.
        if (callee.isKind(.member) and std.mem.eql(u8, self.srcText(ir.Member.name(callee)), "is_empty") and ir.Call.args(sexp).len == 0) if (self.typeOf(ir.Member.object(callee))) |t| {
            if (self.isCellListTy(t) or self.hasLen(t) or self.facts.unwrapAccess(t) == self.facts.types.string_id or self.hasLenReached(t)) {
                try self.w.writeAll("(");
                try self.emitMemberNamed(callee, "len");
                return self.w.writeAll(" == 0)");
            }
        };
        // A Cell holding a List answers the List's members.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isCellListTy(t)) {
            const m = self.srcText(ir.Member.name(callee));
            const method: ?[]const u8 = if (std.mem.eql(u8, m, "push"))
                "listPush"
            else if (std.mem.eql(u8, m, "pop"))
                "listPop"
            else if (std.mem.eql(u8, m, "clear"))
                "listClear"
            else if (std.mem.eql(u8, m, "keep"))
                "listKeep"
            else if (std.mem.eql(u8, m, "get") and ir.Call.args(sexp).len == 1) "listGet" else null;
            if (method) |name| {
                try self.emitCellPtr(ir.Member.object(callee));
                try self.w.print(".{s}(", .{name});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        // `task.all(a, b, ...)`: the tasks, waited for together.
        if (self.facts.isTaskJoin(sexp)) {
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(if (out != null) "rig.waitTasksInto(.{ " else "rig.waitTasks(.{ ");
            try self.emitArgs(sexp);
            if (out) |o| return self.w.print(" }}, {s})", .{o});
            return self.w.writeAll(" })");
        }
        // `par.map(?xs, f, limit: n)`, `par.each(!xs, f, limit: n)`: run
        // by the runtime, with no limit but the workers' count when none
        // is given; `par.workers(!states, ?items, f)`, one task a state.
        // `c.m(args)` through an actor's handle: a message the runtime
        // sends, which waits for the answer.
        if (self.facts.isActorCall(sexp)) {
            const obj = ir.Member.object(callee);
            try self.w.writeAll("rig.actorCall(");
            try self.emitMemberBase(obj, self.typeOf(obj) orelse return self.unsupported(obj, "an untyped actor handle"));
            try self.w.print(", \"{s}\", .{{ ", .{self.srcText(ir.Member.name(callee))});
            try self.emitArgs(sexp);
            return self.w.writeAll(" })");
        }
        // `task.select(arm, ...)`: each arm a channel operation and the
        // function the runtime calls when it is the one that commits.
        if (self.facts.isSelect(sexp)) {
            // The runtime calls the arm's function with the slot a `!` or
            // `catch` lends (`selectInto`).
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(if (out != null) "rig.selectInto(.{ " else "rig.select(.{ ");
            for (args, 0..) |arm, i| {
                if (i > 0) try self.w.writeAll(", ");
                try self.emitExpr(arm);
            }
            if (out) |o| return self.w.print(" }}, {s})", .{o});
            return self.w.writeAll(" })");
        }
        // An arm of `task.select`: the channel, the value an arm sends,
        // and the function the runtime calls.
        if (self.facts.selectArmOf(sexp)) |kind| {
            const handle = ir.get(ir.Member.object(callee), .operand);
            try self.w.writeAll(if (kind == .recv) "rig.recvArm(" else "rig.sendArm(");
            try self.emitMemberBase(handle, self.typeOf(handle) orelse return self.unsupported(handle, "an untyped channel"));
            try self.w.writeAll(", ");
            try self.emitArgs(sexp);
            return self.w.writeAll(")");
        }
        // `http.serve(<listener, f)`: the runtime's server.
        if (self.facts.isHttpServe(sexp)) {
            // The runtime's own call, which takes no slot.
            _ = self.takeFailSlot(sexp);
            try self.w.writeAll("rig.httpServe(");
            try self.emitArgs(sexp);
            return self.w.writeAll(")");
        }
        // `io.copy(!from, !to)`: the runtime's, for files and sockets.
        // `xs.reduce(start, f)`: `rig.reduce(elems, start, f)`.
        if (self.facts.isReduceCall(sexp)) {
            // A failure's fields go to the slot its `!` or `catch` lends.
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(if (out != null) "rig.reduceInto(" else "rig.reduce(");
            try self.emitElems(ir.Member.object(callee));
            try self.w.writeAll(", ");
            try self.emitArgs(sexp);
            if (out) |o| try self.w.print(", {s}", .{o});
            return self.w.writeAll(")");
        }
        if (self.facts.isIoCopy(sexp)) {
            // The runtime's own call, which takes no slot.
            _ = self.takeFailSlot(sexp);
            try self.w.writeAll("rig.net.copy(");
            try self.emitArgs(sexp);
            return self.w.writeAll(")");
        }
        // `task.supervise(f, restarts: n, per: ns)`: isolated again and
        // again by the runtime, with each option or its default.
        if (self.facts.isSuperviseCall(sexp)) {
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(if (out != null) "rig.superviseInto(" else "rig.supervise(");
            try self.emitExpr(args[0]);
            for ([_][]const u8{ "restarts", "per" }, [_][]const u8{ "-1", "0" }) |name, default| {
                try self.w.writeAll(", ");
                const given = for (args[1..]) |a| {
                    if (std.mem.eql(u8, self.srcText(ir.Kwarg.name(a)), name)) break ir.Kwarg.value(a);
                } else null;
                if (given) |v| try self.emitExpr(v) else try self.w.writeAll(default);
            }
            if (out) |o| try self.w.print(", {s}", .{o});
            return self.w.writeAll(")");
        }
        // `task.isolate(f)`: run apart by the runtime.
        if (self.facts.isIsolateCall(sexp)) {
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(if (out != null) "rig.isolateInto(" else "rig.isolate(");
            try self.emitArgs(sexp);
            if (out) |o| try self.w.print(", {s}", .{o});
            return self.w.writeAll(")");
        }
        if (self.facts.parCallOf(sexp)) |kind| {
            const out = self.takeFailSlot(sexp);
            try self.w.writeAll(switch (kind) {
                .map => "rig.parMap",
                .each => "rig.parEach",
                .workers => "rig.parWorkers",
            });
            try self.w.writeAll(if (out != null) "Into(" else "(");
            try self.emitArgs(sexp);
            if (kind != .workers and args.len == 2) try self.w.writeAll(", 0");
            if (out) |o| try self.w.print(", {s}", .{o});
            return self.w.writeAll(")");
        }
        // A set's waits, `>ts` and `<ts.wait_first()`, with no deadline
        // of their own: a deadline is the task's (`time.within`).
        // A wait whose failure may carry fields gives them to the slot
        // its `!` or `catch` lends (`waitInto`, `wait_allInto`, ...).
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isBuiltinInstance(t, self.facts.tasks_sym_id)) {
            const out = self.takeFailSlot(sexp);
            if (rig.isWaitMember(callee)) {
                try self.emitMemberNamed(callee, "wait_all");
                return self.writeSlotCall(out);
            }
            const m = self.srcText(ir.Member.name(callee));
            if (std.mem.eql(u8, m, "wait_first")) {
                try self.emitExpr(callee);
                return self.writeSlotCall(out);
            }
            if (out) |o| self.fail_slot = .{ .call = sexp, .expr = o };
        };
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isBuiltinInstance(t, self.facts.task_sym_id)) if (self.takeFailSlot(sexp)) |o| {
            try self.emitExpr(callee);
            return self.writeSlotCall(o);
        };
        try self.checkCallTarget(sexp);
        // `get` on an array, a slice, or a `?String`.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isSequence(t) and std.mem.eql(u8, self.srcText(ir.Member.name(callee)), "get")) {
            try self.w.writeAll("rig.elementAt(");
            try self.emitBare(ir.Member.object(callee));
            try self.w.writeAll(", ");
            try self.emitArgs(sexp);
            return self.w.writeAll(")");
        };
        // `set`, `swap`, `compare_swap`, `add`, and `sub` change a Cell
        // through any path to it: the Cell's address, a mutable pointer
        // (`emitCellAddress`).
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |t| if (self.isBuiltinInstance(t, self.facts.cell_sym_id)) {
            const m = self.srcText(ir.Member.name(callee));
            if (std.mem.eql(u8, m, "set") or std.mem.eql(u8, m, "swap") or std.mem.eql(u8, m, "compare_swap") or std.mem.eql(u8, m, "add") or std.mem.eql(u8, m, "sub")) {
                try self.emitCellAddress(ir.Member.object(callee));
                try self.w.print(".{s}(", .{m});
                try self.emitArgs(sexp);
                return self.w.writeAll(")");
            }
        };
        try self.emitExpr(callee);
        try self.w.writeAll("(");
        try self.emitArgs(sexp);
        try self.w.writeAll(")");
    }

    /// In a self-checking build, a call of a Rig function or method that
    /// emit writes is one typecheck resolved (`Facts.callTargetOf`): the
    /// frame counts and inlining read that fact, so a call it lacked
    /// would land a frame no count saw.
    fn checkCallTarget(self: *Emitter, call: Sexp) Error!void {
        if (!check_units) return;
        if (self.facts.callTargetOf(call)) |t| if (t == .function) return;
        if (self.facts.callsRigFunction(call)) return self.unsupported(call, "a call of a Rig function no check resolved (callTargetOf)");
    }

    /// An array, a slice, or a `?String`, or a view of one.
    fn isSequence(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .array, .slice, .string_view, .static => true,
            else => false,
        };
    }

    /// A mutable pointer to the Cell `obj` denotes: a shared handle's
    /// value, or the Cell's address.
    fn emitCellPtr(self: *Emitter, obj: Sexp) Error!void {
        const ty = self.typeOf(obj) orelse return self.unsupported(obj, "this Cell");
        // The base of an assignment's target, held in its turn
        // (`hoistBase`), holds the pointer its write view is.
        if (self.hoistedOf(obj)) |h| {
            if (!self.isPtrViewTy(ty)) return self.unsupported(obj, "a held Cell base that is no pointer");
            if (self.facts.types.get(self.peelViews(ty)) == .shared) return self.w.print("(&{s}.*.value)", .{h.name});
            return self.w.print("({s})", .{h.name});
        }
        if (self.facts.types.get(self.peelViews(ty)) == .shared) {
            try self.w.writeAll("(&");
            try self.emitMemberBase(obj, ty);
            return self.w.writeAll(".value)");
        }
        try self.emitCellAddress(obj);
    }

    /// The address of the Cell `obj` denotes, a mutable pointer: a Cell
    /// lives only behind a shared handle, whose value is on the heap, and
    /// every read view of a value holding one is a mutable pointer
    /// (`emitViewPtrTy`).
    fn emitCellAddress(self: *Emitter, obj: Sexp) Error!void {
        if (try self.emitHeldAddress(obj)) return;
        const saved = self.read_place;
        defer self.read_place = saved;
        self.read_place = true;
        try self.w.writeAll("(");
        try self.emitAddressOf(lentPlace(obj));
        try self.w.writeAll(")");
    }

    /// `!h` of a handle `h` that may not be written lends the value the
    /// handle holds, not the handle (`typecheck.lendsHandle`), as its lend
    /// records (the `handle` row): its address is on the heap, the
    /// pointer the lend is, never `h`'s own. False, writing nothing, for
    /// any other lend.
    fn emitHeldAddress(self: *Emitter, lent: Sexp) Error!bool {
        if (!(lent.isKind(.write) or lent.isKind(.read))) return false;
        const lend = self.facts.lendOf(lent) orelse return false;
        if (!lend.has(.handle)) return false;
        try self.w.writeAll("(");
        try self.emitWriteViewPtr(lent);
        try self.w.writeAll(")");
        return true;
    }

    /// `I32(x)` → `@as(i32, @intCast(@as(i64, x)))`, with the builtin
    /// chosen by the kinds of the two types; a signed integer converted to
    /// an unsigned one goes through `openUnsignedCast`. Zig checks that the
    /// value fits in safe builds; `@trunc` truncates toward zero, and
    /// `rig.notNan` panics on a NaN.
    fn emitConversion(self: *Emitter, call: Sexp) Error!void {
        const target = self.typeOf(call) orelse return self.unsupported(call, "an untyped conversion");
        const arg = argValue(ir.Call.args(call)[0]);
        const arg_ty = self.typeOf(arg) orelse return self.unsupported(call, "this conversion");
        // A plain enum's value, converted when the program runs, where
        // Zig checks that it fits (the checker did for a constant one).
        if (self.isEnumTy(self.peelViews(arg_ty))) {
            try self.writeAsOpen(target);
            try self.w.writeAll("@intCast(@backingInt(rig.rt(");
            try self.emitBare(arg);
            return self.w.writeAll("))))");
        }
        // A slot's number, which Zig checks fits a narrower type.
        if (self.facts.types.get(self.peelViews(arg_ty)) == .slot) {
            try self.writeAsOpen(target);
            try self.w.writeAll(if (self.facts.types.get(target) == .int) "@intCast(rig.rt(" else "@floatFromInt(rig.rt(");
            try self.emitBare(arg);
            return self.w.writeAll(")))");
        }
        const from = switch (self.facts.types.get(self.peelViews(arg_ty))) {
            .int, .float => self.peelViews(arg_ty),
            .int_literal => self.facts.types.int_id,
            .float_literal => self.facts.types.float_id,
            else => return self.unsupported(call, "this conversion"),
        };
        const to_int = self.facts.types.get(target) == .int;
        // Constant arithmetic on literals converted to an integer type is
        // a value of it, which the checker made sure fits (it may not fit
        // `Int`).
        if (to_int and self.literalLeaves(arg)) if (self.facts.constIntOf(arg)) |v| {
            try self.writeAsOpen(target);
            return self.w.print("{d})", .{v});
        };
        const from_int = self.facts.types.get(from) == .int;
        // To an unsigned type, through `openUnsignedCast`.
        const unsigned = to_int and from_int and !self.facts.types.get(target).int.signed;
        const builtin = if (to_int) (if (from_int) "@intCast" else "@trunc") else (if (from_int) "@floatFromInt" else "@floatCast");
        const nan_check = to_int and !from_int;
        try self.writeAsOpen(target);
        const through = if (unsigned) try self.openUnsignedCast(arg, from, self.facts.types.get(target).int.width()) else false;
        if (!unsigned) try self.w.print("{s}({s}", .{ builtin, if (nan_check) "rig.notNan(" else "" });
        try self.writeAsOpen(from);
        // A constant is converted at run time, where Zig checks it as Rig
        // does, not at compile time.
        const saved_rt = self.rt_names;
        defer self.rt_names = saved_rt;
        self.rt_names = true;
        try self.emitBare(arg);
        if (unsigned) {
            try self.w.writeAll(")");
            try self.closeUnsignedCast(through);
            return self.w.writeAll(")");
        }
        try self.w.writeAll(if (nan_check) "))))" else ")))");
    }

    /// `(|n| print n)()`: the closure is built and called in a block.
    fn emitInlineInvoke(self: *Emitter, call: Sexp) Error!void {
        const id = self.nextId();
        const name = try self.hiddenStorage(ir.Call.callee(call), .invoked, .owned, .{ .id = id });
        try self.w.print("__rig_inline_{d}: ", .{id});
        try self.openBrace();
        try self.writeIndent(self.indent);
        if (try self.emitStackClosure(name, ir.Call.callee(call))) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.w.print("defer rig.dropFields(&{s});", .{name});
        }
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_inline_{d} {s}.__rig_invoke(", .{ id, name });
        try self.emitArgs(call);
        try self.w.writeAll(");\n");
        try self.closeBrace();
    }

    /// A call's arguments in parameter order: its compile-time arguments
    /// (after a receiver passed as an argument), then its run-time ones,
    /// keyword arguments in their parameters' places and defaults for
    /// omitted ones.
    fn emitArgs(self: *Emitter, call: Sexp) Error!void {
        return self.emitArgsFrom(call, 0);
    }

    /// `emitArgs` from parameter `from` on: a call through an API
    /// object's table passes its self, the first argument of
    /// `Shape.area(s)`, apart (`emitObjectCall`).
    fn emitArgsFrom(self: *Emitter, call: Sexp, from: usize) Error!void {
        const args = ir.Call.args(call);
        const params = self.callParams(call);
        const generic = self.facts.genericCallOf(call);
        const ct_at: usize = if (generic) |g| @intFromBool(g.receiver_arg) else 0;
        const slots = self.facts.callSlotsOf(call);
        const n = if (slots) |sl| sl.len else args.len;
        var written: usize = 0;
        // The witnesses a method under bounds takes come first among its
        // compile-time arguments, after self.
        const owner_ws = self.facts.ownerWitnessesOf(call);
        for (0..n + 1) |i| {
            if (owner_ws) |ow| if (i == @min(@intFromBool(ow.receiver_arg), n)) for (ow.witnesses) |w| {
                if (written > 0) try self.w.writeAll(", ");
                written += 1;
                try self.writeWitness(w);
            };
            if (i == @min(ct_at, n)) {
                const ct = self.facts.ctArgsOf(call);
                if (written > 0 and ctArgCount(generic, ct) > 0) try self.w.writeAll(", ");
                written += try self.emitCtArgs(generic, ct);
            }
            if (i == n) break;
            if (i < from) continue;
            if (written > 0) try self.w.writeAll(", ");
            written += 1;
            if (slots) |sl| switch (sl[i]) {
                .arg => |ai| try self.emitArg(args[ai], params, i),
                .default => |d| try self.emitDefault(self.semaOf(d.source) orelse return self.unsupported(call, "this default argument"), d.expr, if (i < params.len) params[i] else facts.type_invalid),
            } else try self.emitArg(args[i], params, i);
        }
        // The slot its `!` or `catch` lends a call that may fail with
        // fields, when the callee takes one: a Rig function or a function
        // value, never a method of a built-in type.
        if (self.fail_slot) |s| if (sameNode(s.call, call)) {
            self.fail_slot = null;
            if (self.calleeTakesSlot(call)) try self.w.print("{s}{s}", .{ if (written > 0) ", " else "", s.expr });
        };
    }

    /// Whether `call`'s callee takes the slot a failure's fields go in:
    /// a Rig function (`callTargetOf`), or a function value, whose type
    /// takes it (`emitCallableTy`). A built-in type's method, and a call
    /// the runtime makes itself, take none.
    fn calleeTakesSlot(self: *Emitter, call: Sexp) bool {
        if (self.facts.callTargetOf(call)) |t| if (t == .function) return true;
        // A witness's method is a Rig method, or a default or an
        // addition's; an API object's table entry takes the slot of every
        // fallible method.
        if (self.facts.dispatchOf(call)) |d| if (d.viaApi()) return true;
        // An actor's method, which the actor calls with the arguments.
        if (self.facts.isActorCall(call)) return true;
        const callee = self.facts.calleeOf(call);
        // A method of a type parameter's instance, in a generic body: the
        // instance's own Rig method, as the body requires of it.
        if (callee.isKind(.member)) if (self.typeOf(ir.Member.object(callee))) |obj_ty| {
            if (self.facts.types.get(self.peelViews(obj_ty)) == .type_var) return true;
        };
        if (callee == .src) if (self.localOf(callee)) |local| if (local.stack_closure) return true;
        const ty = self.typeOf(callee) orelse return false;
        if (self.facts.callableFn(ty) != null or self.facts.ownedClosureFn(ty) != null) return true;
        if (self.facts.types.get(self.peelViews(ty)) != .function) return false;
        // A plain function value, held by a name or a field of an object;
        // never a method of a built-in type.
        if (callee == .src) return true;
        if (!callee.isKind(.member)) return false;
        const obj_ty = self.typeOf(ir.Member.object(callee)) orelse return false;
        const name = self.srcText(ir.Member.name(callee));
        for (self.declFields(self.peelViews(obj_ty))) |f| {
            if (!f.is_method and !f.is_variant and std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    /// What a `catch |name|` handler starts with: `name` bound to the
    /// error captured as `tmp`. An error that carries fields is an owned
    /// local made of the code and its slot's fields, dropped where the
    /// handler ends unless moved; any other is the code itself.
    fn catchBinding(self: *Emitter, sym: SymbolId, name: Sexp, tmp: []const u8, slot: ?[]const u8) Error!Prelude {
        const ty = self.symType(sym) orelse self.facts.types.any_error_id;
        if (!self.isErrorValueTy(ty)) {
            const local = try self.declare(.{ .sym = sym, .ty = ty }, self.srcText(name));
            return .{ .err_capture = .{ .zig_name = local.zig_name, .tmp = tmp, .ty = ty } };
        }
        var l: Local = .{ .sym = sym, .ty = ty, .kind = self.holdOf(sym) };
        if (l.kind != null) l.guard = self.resourceGuard(sym);
        const stored = try self.declare(l, self.srcText(name));
        const expr = try self.fmt("rig.ErrorValue.taken({s}, &{s})", .{ tmp, slot orelse "rig.no_error_data" });
        return .{ .owned = try self.arena.allocator().dupe(OwnedBinding, &.{.{ .local = stored.*, .expr = expr }}) };
    }

    /// The code of the error value at `place`, as the Zig set of `ty`'s
    /// codes, so a `switch` on a declared set names every member.
    fn writeErrorCode(self: *Emitter, viewed: TypeId, place: []const u8) Error!void {
        const ty = self.peelViews(viewed);
        // A set parameter's code may be of any set, as `error`'s is.
        if (ty == self.facts.types.any_error_id or self.facts.isSetParam(ty)) return self.w.print("{s}.code", .{place});
        const saved = self.error_codes;
        self.error_codes = true;
        defer self.error_codes = saved;
        try self.w.writeAll("@as(");
        try self.emitTypeTy(ty);
        try self.w.print(", @errorCast({s}.code))", .{place});
    }

    /// The slot a `!` or `catch` lends `call`, taken by the one writing
    /// it; null where it lends none.
    fn takeFailSlot(self: *Emitter, call: Sexp) ?[]const u8 {
        const s = self.fail_slot orelse return null;
        if (!sameNode(s.call, call)) return null;
        self.fail_slot = null;
        return s.expr;
    }

    /// The arguments of a runtime wait that may be given a slot: `()`, or
    /// `Into(slot)`.
    fn writeSlotCall(self: *Emitter, out: ?[]const u8) Error!void {
        if (out) |o| return self.w.print("Into({s})", .{o});
        return self.w.writeAll("()");
    }

    /// The slot a `catch` lends its call `value` when the call may fail
    /// with fields: a block that holds it opens here, and the call is
    /// given it (`emitArgs`).
    /// `saved` is the slot lent to a call around this one, given back
    /// when this one's block closes.
    const CatchSlot = struct { name: []const u8, label: []const u8, saved: @FieldType(Emitter, "fail_slot") };

    fn openCatchSlot(self: *Emitter, value: Sexp) Error!?CatchSlot {
        if (!self.failsWithFieldsCall(value)) return null;
        const id = self.nextId();
        const slot: CatchSlot = .{ .name = try self.fmt("__rig_fail_{d}", .{id}), .label = try self.fmt("__rig_fb_{d}", .{id}), .saved = self.fail_slot };
        try self.w.print("({s}: {{ var {s}: rig.ErrData = undefined; break :{s} ", .{ slot.label, slot.name, slot.label });
        self.fail_slot = .{ .call = value, .expr = try self.fmt("rig.failSlot(&{s})", .{slot.name}) };
        return slot;
    }

    fn closeCatchSlot(self: *Emitter, slot: ?CatchSlot) Error!void {
        const s = slot orelse return;
        self.fail_slot = s.saved;
        try self.w.writeAll("; })");
    }

    /// Whether `value`, the operand of a `!` or `catch`, is a call that
    /// may fail with fields, to which they lend a slot.
    fn failsWithFieldsCall(self: *Emitter, value: Sexp) bool {
        if (!value.isKind(.call)) return false;
        if (self.failsWithFields(self.typeOf(value))) return true;
        // A function generic over its set takes the slot whatever set the
        // call binds, as a callable view of a fallible function does
        // (`emitCallableTy`).
        if (self.facts.genericCallOf(value)) |g| if (g.fails_by_set) return true;
        // An API object's table entry for a fallible method takes the
        // slot, whatever its set, as a callable view does.
        if (self.facts.dispatchOf(value)) |d| if (d == .dynamic) {
            const ty = self.typeOf(value) orelse return false;
            return self.facts.types.get(ty) == .fallible;
        };
        const f = self.facts.callableFn(self.typeOf(self.facts.calleeOf(value)) orelse return false) orelse return false;
        return self.facts.types.get(f.returns) == .fallible;
    }

    /// A field or parameter default, `e`, declared in module `decl`: a
    /// literal, a constant, or (a field's, emitted in its own module's
    /// type) a constructor. A constant of another module than the one
    /// being emitted is reached through its file, which every module of
    /// the package can import.
    fn emitDefault(self: *Emitter, decl: Facts, e: Sexp, target: TypeId) Error!void {
        // A default that becomes an optional where it goes (`liftOf`, in
        // its own module's types) is packed into each level of `target`
        // that goes through the helpers.
        if (!sameNode(e, self.lifting)) if (decl.liftOf(e)) |lift| {
            const saved = self.lifting;
            defer self.lifting = saved;
            self.lifting = e;
            const levels = if (lift.from == decl.types.none_id) 1 else optionalDepth(decl.types, lift.into) -| optionalDepth(decl.types, lift.from);
            var into = target;
            while (self.facts.types.get(into) == .fallible) into = self.facts.types.get(into).fallible.ok;
            const opened = try self.openPacks(into, levels);
            try self.emitDefault(decl, e, target);
            for (0..opened) |_| try self.w.writeAll(")");
            return;
        };
        // A member of an error set: `.name` or `E.name`.
        if (e.isKind(.enum_lit) or decl.isErrorMember(e)) if (decl.typeOf(e)) |t| if (decl.nominalDecl(t)) |set| if (set.symbol().flags.error_set) {
            const name = if (e.isKind(.member)) ir.Member.name(e) else ir.EnumLit.name(e);
            try self.w.writeAll("error.");
            return writeErrorName(self.w, set.facts, set.symbol().name, rig.leafText(decl.source, name.src));
        };
        // `:name`, a symbol of the one program-wide set.
        if (e.isKind(.symbol)) {
            self.uses_symbols = true;
            return self.w.print("__rig_sym.Symbol.@\"{s}\"", .{rig.leafText(decl.source, ir.Symbol.name(e).src)});
        }
        if (isDefaultLiteralNode(decl.source, e)) {
            if (self_check and e == .src) if (decl.typeOf(e)) |t| if (decl.nominalDecl(t) != null and std.mem.eql(u8, rig.leafText(decl.source, e.src), "none")) return self.unsupported(e, "`none` with an enum type");
            return writeLiteral(self.w, decl.source, e);
        }
        if (e.isKind(.call) and decl.stringCall(e) == .new) return self.w.writeAll("rig.String.empty");
        if (decl.same(self.facts)) {
            const saved = self.keep_comptime;
            defer self.keep_comptime = saved;
            self.keep_comptime = true;
            return self.emitBare(e);
        }
        if (e.isKind(.member)) {
            const obj = ir.Member.object(e);
            const name = rig.leafText(decl.source, ir.Member.name(e).src);
            if (decl.intLimit(e)) |limit| return self.w.print("{d}", .{limit.v});
            const module = if (decl.symbolOf(obj)) |id| decl.symbols.items[id].kind == .module else false;
            if (!module) if (decl.typeOf(e)) |t| if (decl.types.get(t) == .float) {
                // A float type's limit, named through the type or an
                // alias of it, this module's or an imported one.
                const bits = decl.types.get(t).float.bits;
                return self.w.print("{s}std.math.floatMax(f{d})", .{ if (std.mem.eql(u8, name, "min")) "-" else "", if (bits == 0) 64 else bits });
            };
            if (obj != .src) return self.unsupported(e, "this default value");
            const local = rig.leafText(decl.source, obj.src);
            for (0..decl.importCount()) |i| {
                const imp = decl.importAt(i);
                if (std.mem.eql(u8, imp.local_name, local)) return self.w.print("@import(\"{s}\").{f}", .{ imp.facts.zig_file, ident(name) });
            }
            return self.unsupported(e, "a default from an unresolved module");
        }
        return self.w.print("@import(\"{s}\").{f}", .{ decl.zig_file, ident(rig.leafText(decl.source, e.src)) });
    }

    /// The checked module whose source is `source`: this one, or one it
    /// reaches.
    fn semaOf(self: *Emitter, source: []const u8) ?Facts {
        return self.facts.moduleWithSource(source);
    }

    /// The argument filling parameter slot `i`: a `!T` parameter receives
    /// a pointer.
    fn emitArg(self: *Emitter, arg: Sexp, params: []const TypeId, i: usize) Error!void {
        const value = argValue(arg);
        // A temporary array lent as a slice: its address, which lives
        // through the call.
        if (self.facts.lendsTempArray(value)) {
            // Where Zig holds it, unless the call evaluated it first.
            if (self.hoistedOf(value) == null) try self.zigTemporary(value);
            try self.w.writeAll("&");
            return self.emitBare(value);
        }
        if (i < params.len and self.isPtrViewTy(params[i])) return self.emitWriteViewPtr(value);
        try self.emitBareAs(value, if (i < params.len) params[i] else null);
    }

    /// The number of compile-time arguments a call passes: those `given`
    /// in its bracket list, or one per compile-time parameter of a
    /// generic function, whose types may be inferred.
    fn ctArgCount(generic: ?facts.GenericCall, given: []const Sexp) usize {
        return if (generic) |g| g.type_args.len else given.len;
    }

    /// A call's compile-time arguments, `given` in its bracket list: for a
    /// generic function, a type argument (inferred or given) where it
    /// takes one. Returns how many were written.
    fn emitCtArgs(self: *Emitter, generic: ?facts.GenericCall, given: []const Sexp) Error!usize {
        const n = ctArgCount(generic, given);
        for (0..n) |j| {
            if (j > 0) try self.w.writeAll(", ");
            const ty = if (generic) |g| g.type_args[j] else facts.type_invalid;
            // A set parameter takes the set's Zig error set, not its value.
            const saved = self.error_codes;
            defer self.error_codes = saved;
            if (generic) |g| if (j < 64 and g.sets & (@as(u64, 1) << @intCast(j)) != 0) {
                self.error_codes = true;
            };
            if (ty != facts.type_invalid) try self.emitTypeTy(ty) else try self.emitComptime(given[j]);
            if (generic) |g| for (g.witnesses) |aw| if (aw.arg == j) {
                try self.w.writeAll(", ");
                try self.writeWitness(aw.witness);
            };
        }
        return n;
    }

    /// A compile-time argument: a value Zig knows at compile time.
    fn emitComptime(self: *Emitter, arg: Sexp) Error!void {
        const saved = self.keep_comptime;
        defer self.keep_comptime = saved;
        self.keep_comptime = true;
        try self.emitBare(arg);
    }

    /// `storage.argParams`.
    fn callParams(self: *Emitter, call: Sexp) []const TypeId {
        return self.facts.argParams(call);
    }

    /// `storage.isTypeCallee`.
    fn isTypeCallee(self: *Emitter, obj: Sexp) bool {
        return self.facts.isTypeCallee(obj);
    }

    /// `storage.moduleMemberSym`.
    fn moduleMemberSym(self: *Emitter, obj: Sexp) ?facts.Symbol {
        return self.facts.moduleMemberSym(obj);
    }

    /// A struct, enum, or generic type: calling it constructs a value.
    /// A callee naming a type alias, this module's or an imported one.
    fn isAliasCallee(self: *Emitter, callee: Sexp) bool {
        if (callee.isKind(.member)) return if (self.moduleMemberSym(callee)) |m| m.kind == .type_alias else false;
        if (callee != .src) return false;
        const id = self.facts.symbolOf(callee) orelse return false;
        return self.facts.symbols.items[id].kind == .type_alias;
    }

    /// `storage.isTypeSym`.
    fn isTypeSym(self: *Emitter, id: SymbolId) bool {
        return self.facts.isTypeSym(id);
    }
    /// `storage.hoistsArgs`.
    fn hoistsArgs(self: *Emitter, call: Sexp) Error!bool {
        return self.need(self.facts.hoistsArgs(call), call);
    }

    /// `storage.lentLiteral`.
    fn lentLiteral(self: *Emitter, e: Sexp) bool {
        return self.facts.lentLiteral(e);
    }

    /// `storage.consumedTemporary`.
    fn consumedTemporary(self: *Emitter, call: Sexp) Error!?Sexp {
        return if (try self.need(self.facts.consumesReceiver(call), call)) self.facts.receiverOf(call) else null;
    }

    /// `storage.isPureArg`.
    fn isPureArg(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.isPureArg(e), e);
    }

    /// `storage.receiverOf`.
    fn receiverOf(self: *Emitter, call: Sexp) ?Sexp {
        return self.facts.receiverOf(call);
    }

    /// Whether an operand tested against `none` or a bare `.variant` is
    /// a value made there that no slot holds, which the test drops. Any
    /// other operand is read where it is.
    fn dropsWhenTested(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.dropsWhenTested(e), e);
    }

    /// `storage.hasStorage`.
    fn hasStorage(self: *Emitter, e: Sexp) Error!bool {
        return self.need(self.facts.hasStorage(e), e);
    }

    /// `storage.receiverWrites`.
    fn receiverWrites(self: *Emitter, call: Sexp) bool {
        return self.facts.receiverWrites(call);
    }

    /// Evaluate the receiver of a method call whose arguments are hoisted
    /// into `__rig_recv_N` first, so it runs before them, as written: the
    /// address of a place, or a temporary value, dropped after the call.
    fn hoistReceiver(self: *Emitter, call: Sexp, id: u32) Error!void {
        const hold = (try self.need(self.facts.receiverHold(call), call)) orelse return;
        // Lend sigils on a receiver are implicit in Zig's method calls.
        const recv = lentPlace(self.receiverOf(call).?);
        const writes = self.receiverWrites(call);
        // Held as written below: an address, or a value made here.
        const by: facts.StorageBy = switch (hold) {
            .leaf, .slot, .place => .pointer,
            .consumed, .value => .owned,
        };
        const name = try self.hiddenStorage(recv, .receiver, by, .{ .id = id });
        try self.writeIndent(self.indent);
        // A value that branches is held as the address of the leaf it
        // takes, and a value kept in its statement's slot, or a part of
        // one, as its address there: never a copy, which the call's block
        // would end while the result may still view it.
        if (hold == .leaf or hold == .slot) {
            try self.w.print("const {s} = ", .{name});
            if (hold == .leaf) try self.emitLeafPtr(recv, self.typeOf(recv).?) else try self.emitSlotAddress(recv);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = recv, .name = name, .ptr = self.reachesHandle(self.typeOf(recv)) });
        }
        if (hold == .place) {
            const saved = self.read_place;
            defer self.read_place = saved;
            self.read_place = !writes;
            try self.w.print("const {s} = ", .{name});
            try self.emitAddressOf(recv);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = recv, .name = name, .ptr = self.reachesHandle(self.typeOf(recv)) });
        }
        const ty = self.typeOf(recv);
        const ptr = if (ty) |t| self.isPtrViewTy(t) else false;
        const kind: ?ResourceKind = if (ptr) null else try self.dropKind(recv);
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional or (writes and !ptr)) "var" else "const", name });
        if (ty) |t| {
            try self.w.writeAll(": ");
            try self.emitTypeTy(t);
        }
        try self.w.writeAll(" = ");
        try self.emitBare(recv);
        try self.w.writeAll(";\n");
        if (kind == .value or kind == .optional or (writes and !ptr)) try self.poisonAtExit(name);
        // Sema rejects a viewed temporary receiver that owns a resource
        // (a consumed one is hoisted by `consumedTemporary`), so only a
        // value holding a type parameter gets here (`@twice()` of a
        // `Wrap[T]`): plain data in every instance sema accepts, dropped
        // like a resource in the generic body.
        if (kind) |k| {
            try self.writeIndent(self.indent);
            try self.w.writeAll("defer ");
            try self.writeDrop(name, k);
            try self.w.writeAll(";\n");
        }
        try self.hoisted.append(self.allocator, .{ .node = recv, .name = name });
    }

    /// Every argument that is not pure goes into a typed temporary, in
    /// source order, after the receiver (see `hoistReceiver`), and the
    /// call itself runs last. An owned temporary, including a receiver
    /// the method consumes, is dropped if a later argument leaves, and
    /// handed to the callee (its flag cleared) only when the call runs.
    /// `pair(mk(1)!, mk(2)!)`, with `mk` returning a `List[Int]`:
    ///
    ///     __rig_call_N: {
    ///         var __rig_arg_N_0: rig.List(i64) = try mk(1);
    ///         var __rig_live_N_0 = true;
    ///         defer if (__rig_live_N_0) rig.drop(&__rig_arg_N_0);
    ///         var __rig_arg_N_1: rig.List(i64) = try mk(2);
    ///         ...
    ///         break :__rig_call_N pair(rig.take(&__rig_live_N_0, __rig_arg_N_0), ...);
    ///     }
    fn emitHoistedCall(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        const params = self.callParams(call);
        const slots = self.facts.callSlotsOf(call);
        const fields = self.buildsValue(call);
        const id = self.nextId();
        try self.w.print("__rig_call_{d}: ", .{id});
        try self.openBrace();
        const first = self.hoisted.items.len;
        if (try self.consumedTemporary(call)) |recv| {
            try self.hoist(.{ .node = recv, .name = try self.hiddenStorage(recv, .receiver, .owned, .{ .id = id }), .flag = try self.fmt("__rig_live_{d}_recv", .{id}) }, null, &.{}, 0, false);
        } else try self.hoistReceiver(call, id);
        for (args, 0..) |a, ai| {
            const value = argValue(a);
            if (try self.isPureArg(value)) continue;
            const slot: usize = if (slots) |ss| for (ss, 0..) |s, i| {
                if (s == .arg and s.arg == ai) break i;
            } else ai else ai;
            try self.hoist(.{ .node = value, .name = "", .flag = try self.fmt("__rig_live_{d}_{d}", .{ id, ai }) }, .{ .pair = .{ id, @intCast(ai) } }, params, slot, fields);
        }
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_call_{d} ", .{id});
        try self.emitCallDirect(call);
        self.hoisted.shrinkRetainingCapacity(first);
        try self.w.writeAll(";\n");
        try self.closeBrace();
    }

    /// Evaluate `h.node`, the argument for parameter slot `slot` (or a
    /// field value when the call `fields` builds a value), into the
    /// temporary `h.name`. One that owns a resource is dropped at the end
    /// of the call's block unless the call takes it, clearing `h.flag`.
    /// An argument's storage is named here (`suffix`), held as it is
    /// written: a receiver the method consumes comes named.
    fn hoist(self: *Emitter, h_in: Hoisted, suffix: ?StorageSuffix, params: []const TypeId, slot: usize, fields: bool) Error!void {
        var h = h_in;
        // A consumed receiver (no suffix: its storage is named) is a value
        // of its own; an argument is held as the plan decided.
        const hold: facts.ArgumentHold = if (suffix == null) .value else try self.need(self.facts.argumentHold(h.node), h.node);
        if (hold == .closure or hold == .callable) {
            const fn_ty = self.facts.callableOf(h.node).?;
            if (suffix) |sx| h.name = try self.hiddenStorage(h.node, .argument, .owned, sx);
            if (hold == .closure) return self.hoistClosure(h, fn_ty);
            // The `rig.FnRef` has the type Zig gives it.
            try self.writeIndent(self.indent);
            try self.w.print("const {s} = ", .{h.name});
            try self.emitLentCallable(h.node, fn_ty);
            try self.w.writeAll(";\n");
            return self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
        }
        const ty = self.typeOf(h.node);
        const ptr = slot < params.len and self.isPtrViewTy(params[slot]);
        // A value lent as the view its parameter expects is held as that
        // view, of the parameter's type, which owns nothing.
        const lent = hold == .lent;
        // A temporary array lent as a slice stays in its slot, which owns
        // nothing to release: an array holds no value that needs cleanup.
        const lent_array = self.facts.lendsTempArray(h.node);
        const kind: ?ResourceKind = if (ptr or lent or lent_array) null else try self.dropKind(h.node);
        if (suffix) |sx| h.name = try self.hiddenStorage(h.node, .argument, if (ptr or lent) .pointer else .owned, sx);
        try self.writeIndent(self.indent);
        try self.w.print("{s} {s}", .{ if (kind == .value or kind == .optional) "var" else "const", h.name });
        // The value alone may have no Zig type (`.empty`, `null`, a
        // literal). A view read through is read here, in argument order.
        // A value lent has the parameter's type.
        const shown: ?TypeId = if (lent) (if (slot < params.len) params[slot] else null) else ty;
        if (shown) |t| if (!ptr) {
            try self.w.writeAll(": ");
            try self.emitTypeTy(if (self.readsThrough(h.node)) self.peelViews(t) else t);
        };
        try self.w.writeAll(" = ");
        {
            // The temporary holds the value as itself; where the call reads
            // it, it becomes the optional it goes into (`emitLift`).
            const saved = self.lifting;
            defer self.lifting = saved;
            if (shown == ty) self.lifting = h.node;
            if (fields) try self.emitStored(h.node) else if (self.facts.lendsTempArray(h.node)) try self.emitBare(h.node) else try self.emitArg(h.node, params, slot);
        }
        try self.w.writeAll(";\n");
        if (kind == .value or kind == .optional) try self.poisonAtExit(h.name);
        const k = kind orelse return self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
        try self.line("var {s} = true;", .{h.flag});
        try self.writeIndent(self.indent);
        try self.w.print("defer if ({s}) ", .{h.flag});
        try self.writeDrop(h.name, k);
        try self.w.writeAll(";\n");
        try self.hoisted.append(self.allocator, h);
    }

    /// `storage.keptInSlot`.

    /// The address of `e` in its statement's slot (`keptInSlot`).
    fn emitSlotAddress(self: *Emitter, e: Sexp) Error!void {
        const saved = self.read_place;
        defer self.read_place = saved;
        self.read_place = true;
        try self.w.writeAll("&(");
        if (self.facts.dropsTemp(e)) try self.emitBare(e) else try self.emitPlace(e);
        try self.w.writeAll(")");
    }

    /// The temporary an argument or receiver was evaluated into, if it was.
    fn hoistedOf(self: *Emitter, e: Sexp) ?Hoisted {
        var i = self.hoisted.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.hoisted.items[i];
            if (sameNode(h.node, e)) return h;
        }
        return null;
    }

    /// A call whose arguments become the fields of the value it builds:
    /// a constructor or a variant.
    fn buildsValue(self: *Emitter, call: Sexp) bool {
        const callee = self.facts.calleeOf(call);
        if (callee.isKind(.enum_lit)) return true;
        if (callee.isKind(.member)) return self.facts.typeOf(callee) == null;
        return self.isConstructorCall(call);
    }

    /// A call `emitCall` lowers with `emitConstructor`, whose Zig spells
    /// the value's type.
    fn isConstructorCall(self: *Emitter, e: Sexp) bool {
        if (!e.isKind(.call) or self.facts.calleeOf(e) != .src) return false;
        if (self.localOf(self.facts.calleeOf(e))) |local| if (local.stack_closure) return false;
        const sym_id = self.facts.symbolOf(self.facts.calleeOf(e)) orelse return false;
        return sym_id != self.facts.list_sym_id and sym_id != self.facts.signal_sym_id and sym_id != self.facts.box_sym_id and self.isTypeSym(sym_id);
    }

    /// Constructor call `Name(field: v, ...)`: a struct literal typed by
    /// sema (a generic type's arguments come from the call's type).
    fn emitConstructor(self: *Emitter, call: Sexp, sym_id: SymbolId) Error!void {
        if (self.facts.symbols.items[sym_id].kind != .generic_type) if (self.typeOf(call)) |ty| if (self.facts.namedNoneOf(ty) != null) return self.emitNamedNoneConstructor(call, sym_id);
        if (self.facts.symbols.items[sym_id].kind == .generic_type) {
            const ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped generic constructor");
            try self.emitTypeTy(ty);
        } else {
            try self.writeNominalName(sym_id);
        }
        try self.emitFieldInit(ir.Call.args(call), self.facts.symbols.items[sym_id].fields orelse &.{});
    }

    /// The members of the struct or enum type `ty` is declared as.
    fn declFields(self: *Emitter, ty: TypeId) []const facts.Field {
        const decl = self.facts.nominalDecl(ty) orelse return &.{};
        return decl.symbol().fields orelse &.{};
    }

    /// The type a constructor's bracket list gives (`List[Int]()`), before
    /// the decl literal that builds it.
    fn emitGivenType(self: *Emitter, call: Sexp) Error!void {
        const inst = self.facts.instanceOf(ir.Call.callee(call)) orelse return;
        if (inst == .type) try self.emitTypeTy(inst.type);
    }

    /// `{ .a = x, ... }` from keyword arguments, or from the one
    /// positional argument of a type or variant whose `fields` hold one
    /// data field.
    fn emitFieldInit(self: *Emitter, args: []const Sexp, fields: []const facts.Field) Error!void {
        var sole: ?facts.Field = null;
        for (fields) |f| {
            if (f.is_method or f.is_variant) continue;
            sole = if (sole == null) f else null;
            if (sole == null) break;
        }
        try self.w.writeAll("{");
        for (args, 0..) |a, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            if (!a.isKind(.kwarg)) {
                const f = sole orelse return self.unsupported(a, "a positional field");
                try self.w.print(".{f} = ", .{ident(f.name)});
                try self.emitStored(a);
                continue;
            }
            try self.w.print(".{f} = ", .{ident(self.srcText(ir.Kwarg.name(a)))});
            try self.emitStored(ir.Kwarg.value(a));
        }
        try self.w.writeAll(if (args.len > 0) " }" else "}");
    }

    /// A constructor of an object that names its none (`none id == 0`):
    /// its field's value, checked to be some other value.
    fn emitNamedNoneConstructor(self: *Emitter, call: Sexp, sym_id: SymbolId) Error!void {
        const args = ir.Call.args(call);
        const none = self.facts.namedNoneOf(self.typeOf(call).?).?;
        const name = self.facts.symbols.items[sym_id].name;
        const value = if (none.variant) |v| try self.fmt(".{s}", .{v}) else try self.fmt("{d}", .{none.value});
        const why = try self.fmt("a `{s}` never holds `{s}` {s}, which is what a `{s}?` holds for `none`", .{ name, none.field, value, name });
        try self.w.writeAll("rig.notNone(");
        try self.writeNominalName(sym_id);
        try self.w.print(", \"{f}\", ", .{std.zig.fmtString(why)});
        try self.writeNominalName(sym_id);
        try self.emitFieldInit(args, self.facts.symbols.items[sym_id].fields orelse &.{});
        try self.w.writeAll(")");
    }

    /// `List()` / `List(capacity: n)` / `List(a)`: a decl literal of the
    /// type sema gave it, which a `catch` or `??` handler cannot take from
    /// its result location. `List(a)` copies the elements of the array or
    /// slice `a` (`fromSlice`).
    fn emitListConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        try self.emitTypeTy(self.typeOf(call) orelse return self.unsupported(call, "an untyped List construction"));
        if (args.len == 1 and !args[0].isKind(.kwarg)) {
            const arg_ty = self.peelViews(self.typeOf(args[0]) orelse return self.unsupported(call, "an untyped List source"));
            try self.w.writeAll(".fromSlice(");
            if (self.facts.types.get(arg_ty) == .array) {
                try self.w.writeAll("&");
                try self.emitBare(args[0]);
            } else try self.emitBare(args[0]);
            return self.w.writeAll(")");
        }
        if (args.len == 1) {
            try self.w.writeAll(".initCapacity(");
            try self.emitBare(ir.Kwarg.value(args[0]));
            return self.w.writeAll(")");
        }
        try self.w.writeAll(".empty");
    }

    /// `Table()`: its `n` slots reserved or made as it runs (`rig.Table`).
    fn emitTableConstruction(self: *Emitter, call: Sexp) Error!void {
        try self.emitTypeTy(self.typeOf(call) orelse return self.unsupported(call, "an untyped Table construction"));
        try self.w.writeAll(".init()");
    }

    /// `Signal(v)`.
    fn emitSignalConstruction(self: *Emitter, call: Sexp) Error!void {
        const args = ir.Call.args(call);
        if (args.len != 1) return self.unsupported(call, "this Signal construction");
        try self.emitGivenType(call);
        try self.w.writeAll(".init(");
        try self.emitBare(argValue(args[0]));
        try self.w.writeAll(")");
    }

    /// `^v`: `v` moved into a new heap allocation. `^[n of x]` fills the
    /// allocation itself (`storage.fillsInPlace`).
    fn emitBox(self: *Emitter, sexp: Sexp) Error!void {
        try self.emitTypeTy(self.typeOf(sexp) orelse return self.unsupported(sexp, "an untyped box"));
        if (try self.need(self.facts.fillsInPlace(sexp), sexp)) {
            try self.w.writeAll(".fill(");
            try self.emitBare(ir.ArrayFill.value(ir.Box.operand(sexp)));
            return self.w.writeAll(")");
        }
        try self.w.writeAll(".init(");
        try self.emitStored(ir.Box.operand(sexp));
        try self.w.writeAll(")");
    }

    /// `E.name(fields...)`: a member of error set `set` with fields. Where
    /// it fails out of the function, its fields go through `__out` and its
    /// code is what the function fails with (`rig.failWith`); anywhere
    /// else it is a `rig.ErrorValue` holding them.
    fn emitErrorMember(self: *Emitter, call: Sexp, set: TypeId, vname: []const u8) Error!void {
        const payload = self.variantPayload(set, vname) orelse return self.unsupported(call, "this error member");
        const failing = self.fun.has_out and self.facts.isFailingLeaf(call);
        if (failing) try self.w.print("@errorCast(rig.failWith({s}, ", .{self.fun.out_name}) else try self.w.writeAll("rig.ErrorValue.of(");
        try self.writeError(set, vname, call);
        try self.w.writeAll(", @as(");
        try self.emitMemberFieldsTy(set, vname);
        try self.w.writeAll(", .");
        try self.emitFieldInit(ir.Call.args(call), payload);
        try self.w.writeAll(if (failing) ")))" else "))");
    }

    /// Whether a function returning `ret` may fail with fields: its set
    /// has a member with fields, or it may fail with any error in a program
    /// that declares one.
    fn failsWithFields(self: *Emitter, ret: ?TypeId) bool {
        const r = ret orelse return false;
        const t = self.facts.types.get(r);
        return t == .fallible and self.isErrorValueTy(t.fallible.set);
    }

    /// `.variant(args)` → `.{ .variant = .{ .field = value, ... } }`.
    fn emitVariantLit(self: *Emitter, call: Sexp) Error!void {
        const vname = self.srcText(ir.EnumLit.name(ir.Call.callee(call)));
        if (ir.Call.args(call).len == 0) return self.w.print(".{f}", .{ident(vname)});
        const enum_ty = self.typeOf(call) orelse return self.unsupported(call, "an untyped variant");
        return self.emitVariantPayload(call, enum_ty, vname);
    }

    fn emitVariantPayload(self: *Emitter, call: Sexp, enum_ty: TypeId, vname: []const u8) Error!void {
        const args = ir.Call.args(call);
        const payload = self.variantPayload(enum_ty, vname) orelse return self.unsupported(call, "this variant");
        try self.w.print(".{{ .{f} = .", .{ident(vname)});
        try self.emitFieldInit(args, payload);
        try self.w.writeAll(" }");
    }

    /// `print(a, b)`: the runtime writes each value the way Rig spells it.
    /// It reads a place that owns storage when it is called, after every
    /// argument has run, as the ownership checker holds it
    /// (`holdRead`): such a place goes by address, so a later argument
    /// that changes it through a Cell leaves no copy of what it frees.
    /// Plain data is copied whole where it is read. The call takes print's
    /// pieces: the arguments, a space between two, and the newline
    /// (`rig.print(.{ a, " ", &b, "\n" })`), which the runtime writes as
    /// straight-line code once every argument has run.
    fn emitPrint(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("rig.print(");
        try self.emitPrintArgs(args, print_text);
        try self.w.writeAll(")");
    }

    /// `warn(a, b)`: `print`'s pieces, which the runtime writes to
    /// stderr once stdout is flushed.
    fn emitWarn(self: *Emitter, args: []const Sexp) Error!void {
        try self.w.writeAll("rig.warn(");
        try self.emitPrintArgs(args, print_text);
        try self.w.writeAll(")");
    }

    /// `panic(a, b)`: `print`'s pieces after the place it stands
    /// (`file.rig:L:C: panic: `), which the runtime writes to stderr once
    /// stdout is flushed, and then ends the program.
    fn emitPanic(self: *Emitter, node: Sexp) Error!void {
        const pos = self.facts.startOf(node);
        const at = self.file.locate(pos);
        const lc = diag.lineCol(at.text, pos - at.start);
        const prefix = try self.fmt("{s}:{d}:{d}: panic: ", .{ at.path, lc.line, lc.col });
        var text = print_text;
        text.start = try self.fmt("\"{f}\"", .{std.zig.fmtString(prefix)});
        try self.w.writeAll("rig.fail(");
        try self.emitPrintArgs(ir.Panic.args(node), text);
        try self.w.writeAll(")");
    }

    /// Text `emitPrintArgs` puts among the values, each a Zig string
    /// literal: `start` before the first.
    const PrintText = struct { start: ?[]const u8 = null, sep: ?[]const u8 = null, end: ?[]const u8 = null };

    /// `print`'s text: a space between two values, and a newline.
    const print_text: PrintText = .{ .sep = "\" \"", .end = "\"\\n\"" };

    /// The tuple of pieces the runtime's writer reads: the values
    /// (`.{ a, &b }`), with `text.sep` between two and `text.end` after
    /// the last.
    fn emitPrintArgs(self: *Emitter, args: []const Sexp, text: PrintText) Error!void {
        try self.w.writeAll(".{");
        var n: usize = 0;
        if (text.start) |start| try self.emitPiece(&n, start);
        for (args, 0..) |a, i| {
            if (i > 0) if (text.sep) |sep| try self.emitPiece(&n, sep);
            try self.w.writeAll(if (n == 0) " " else ", ");
            n += 1;
            if (try self.printsByAddress(a)) {
                const saved_read = self.read_place;
                defer self.read_place = saved_read;
                self.read_place = true;
                try self.emitAddressOf(a);
            } else try self.emitBare(a);
        }
        if (text.end) |end| try self.emitPiece(&n, end);
        try self.w.writeAll(if (n > 0) " }" else "}");
    }

    /// A piece of text in the tuple `emitPrintArgs` writes, after `n` others.
    fn emitPiece(self: *Emitter, n: *usize, literal: []const u8) Error!void {
        try self.w.writeAll(if (n.* == 0) " " else ", ");
        try self.w.writeAll(literal);
        n.* += 1;
    }

    /// Whether a `print`, `String(...)`, or `add` argument `a` reads a
    /// place that owns storage, or is lent from one: a local, or a
    /// field or element of one (not a slice, which is a new value).
    fn printsByAddress(self: *Emitter, a: Sexp) Error!bool {
        return self.need(self.facts.printsByAddress(a), a);
    }

    // =========================================================================
    // Closures
    // =========================================================================

    const Capture = struct {
        node: Sexp,
        mode: Tag,
        /// The capture's own symbol, seen inside the body.
        sym: SymbolId,
        name: []const u8,
        ty: TypeId,
        /// The captured binding, where the closure is created.
        outer: ?Local,
    };

    fn captureInfo(self: *Emitter, captures: Sexp) Error![]const Capture {
        var out: std.ArrayList(Capture) = .empty;
        for (facts.syntax.captureList(captures)) |cap| {
            const name_node = facts.syntax.captureNameNode(cap).?;
            const sym = self.facts.symbolOf(name_node) orelse return self.unsupported(cap, "an unresolved capture");
            const s = self.facts.symbols.items[sym];
            const outer: ?Local = if (self.localBySym(s.origin)) |l| l.* else null;
            try out.append(self.arena.allocator(), .{ .node = cap, .mode = cap.kind().?, .sym = sym, .name = s.name, .ty = s.ty, .outer = outer });
        }
        return out.items;
    }

    /// `f = |captures| body` → a struct holding the captures with an
    /// `__rig_invoke` method; calls lower to `f.__rig_invoke(...)`. When a capture
    /// owns a resource, the closure is dropped at scope exit, which drops
    /// its fields.
    fn emitClosureBinding(self: *Emitter, name_node: Sexp, sym: SymbolId, lambda: Sexp) Error!void {
        var local: Local = .{ .sym = sym, .stack_closure = true };
        for (try self.captureInfo(ir.Lambda.captures(lambda))) |c| {
            if (self.holdOf(c.sym) != null) local.kind = .value;
        }
        if (local.kind != null) local.guard = self.resourceGuard(sym);
        const stored = try self.declare(local, self.srcText(name_node));
        _ = try self.emitStackClosure(stored.zig_name, lambda);
        if (stored.guard != .none) {
            try self.w.writeAll("\n");
            try self.writeIndent(self.indent);
            try self.emitGuard(stored);
        } else {
            try self.w.print(" _ = &{s};", .{stored.zig_name});
        }
    }

    /// `var name = struct { captures, fn __rig_invoke }{ inits };`. Returns
    /// whether a capture owns a resource.
    fn emitStackClosure(self: *Emitter, zig_name: []const u8, lambda: Sexp) Error!bool {
        const caps = try self.captureInfo(ir.Lambda.captures(lambda));
        try self.w.print("var {s} = ", .{zig_name});
        try self.emitClosureStruct(lambda, caps);
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";");
        for (caps) |c| if (self.holdOf(c.sym) != null) return true;
        return false;
    }

    /// A closure's environment: its captures as fields and a `__rig_invoke`
    /// method taking its parameters.
    ///
    ///     struct { cap_x: T, pub fn __rig_invoke(__rig_self: *@This(), a: A) R { ... } }
    fn emitClosureStruct(self: *Emitter, lambda: Sexp, caps: []const Capture) Error!void {
        const params = ir.Lambda.params(lambda);
        const ret = self.lambdaReturn(lambda);

        try self.w.writeAll("struct ");
        try self.openBrace();
        const env = if (self.closure_depth == 0) "__rig_self" else try self.fmt("__rig_self{d}", .{self.closure_depth});
        var uses_env = false;
        var once_caps: std.ArrayList(SymbolId) = .empty;
        for (caps) |c| {
            try self.writeIndent(self.indent);
            try self.w.print("{s}: ", .{try self.capField(c.name)});
            try self.emitTypeTy(c.ty);
            try self.w.writeAll(",\n");
            const field = try self.fmt("{s}.{s}", .{ env, try self.capField(c.name) });
            const kind = if (self.isPtrViewTy(c.ty)) null else self.holdOf(c.sym);
            if (kind != null and self.facts.isOnceCapture(c.sym)) {
                // A closure called once takes a capture it owns from its
                // environment into a binding of its body, which drops it
                // unless the body moves it out.
                _ = try self.declare(.{ .sym = c.sym, .ty = c.ty, .param_name = field, .kind = kind, .guard = self.resourceGuard(c.sym) }, c.name);
                try once_caps.append(self.arena.allocator(), c.sym);
                uses_env = true;
                continue;
            }
            uses_env = uses_env or self.usage.used.contains(c.sym);
            // Inside the body, a capture is a field of the environment.
            _ = try self.declare(.{ .sym = c.sym, .zig_name = field, .ty = c.ty }, c.name);
        }
        const once = self.facts.isOnceClosure(lambda);
        if (once) try self.line("__rig_called: bool = false,", .{});
        try self.w.writeAll("\n");
        try self.writeIndent(self.indent);
        // A large frame is never inlined into its caller's.
        try self.w.print("pub {s}fn __rig_invoke({s}: *@This()", .{ if (self.facts.isLargeOwner(lambda)) "noinline " else "", env });
        self.closure_depth += 1;
        defer self.closure_depth -= 1;
        const saved_fun = self.fun;
        defer self.fun = saved_fun;
        self.fun = .{ .return_ty = ret, .params = params, .unused_env = if (uses_env or once) "" else env, .once_caps = once_caps.items, .once_env = if (once) env else "" };
        try self.bindParams(params, false);
        for (params.items()) |p| {
            try self.w.writeAll(", ");
            try self.emitParam(p, false);
        }
        // A closure that may fail with fields takes the slot they go in.
        if (self.failsWithFields(ret)) {
            self.fun.has_out = true;
            self.fun.out_unmarked = true;
            self.fun.out_name = try self.fmt("__out_{d}", .{self.closure_depth});
            try self.w.print(", {s}: rig.ErrSlot", .{self.fun.out_name});
        }
        try self.w.writeAll(") ");
        if (ret) |r| try self.emitTypeTy(r) else try self.w.writeAll("void");
        try self.w.writeAll(" ");
        const body = ir.Lambda.body(lambda);
        if (self.lambdaYields(lambda)) try self.emitValueBody(body) else try self.emitBlock(body);
        try self.w.writeAll("\n");
        try self.closeBrace();
    }

    /// The field of a closure's environment that holds capture `name`:
    /// `cap_x`. Self, `@`, is `cap_self`, so a capture named
    /// `self` is `cap_self'`, as `writeZigIdent` renames it.
    fn capField(self: *Emitter, name: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, name, "@")) return "cap_self";
        if (std.mem.eql(u8, name, "self")) return "@\"cap_self'\"";
        // A field path, `p.a` or `@template`, is quoted whole.
        if (std.mem.indexOfAny(u8, name, ".@") != null) return self.fmt("@\"cap_{s}\"", .{name});
        return self.fmt("cap_{s}", .{name});
    }

    /// `{ .cap_x = init, ... }` evaluated where the closure is created.
    fn emitCaptureInit(self: *Emitter, caps: []const Capture) Error!void {
        if (caps.len == 0) return self.w.writeAll("{}");
        try self.w.writeAll("{");
        for (caps, 0..) |c, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.w.print(".{s} = ", .{try self.capField(c.name)});
            // A field path is the lend its sigil makes there.
            const value = facts.syntax.captureValue(c.node);
            if (value != .nil) {
                try self.emitExpr(value);
                continue;
            }
            const outer = c.outer orelse return self.unsupported(c.node, "a capture of a name that is not a local");
            switch (c.mode) {
                .cap_clone => try self.writeCloneCapture(&outer, c.node),
                .cap_weak => {
                    try self.writeLocalPlace(&outer);
                    try self.w.writeAll(".weakRef()");
                },
                .cap_move => if (outer.is_ptr and self.isPtrViewTy(c.ty)) {
                    // A moved pointer view moves the pointer.
                    try self.w.writeAll(outer.zig_name);
                } else try self.writeTake(&outer),
                .cap_read, .cap_write => try self.writeCapturedView(&outer, c.ty),
                else => try self.writeLocalPlace(&outer),
            }
        }
        try self.w.writeAll(" }");
    }

    /// `|+x|`: what `+x` gives of local `outer`, read through a view it
    /// holds (`sema.cloneable`): a handle counted again, an owner cloned
    /// part by part, or a copy of a value that copies.
    fn writeCloneCapture(self: *Emitter, outer: *const Local, node: Sexp) Error!void {
        const ty = outer.ty orelse return self.unsupported(node, "a capture of a value of unknown type");
        switch (self.facts.cloneable(ty)) {
            .bump => switch (self.facts.types.get(self.peelViews(ty))) {
                .optional => {
                    try self.w.writeAll("rig.cloneOptional(");
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(")");
                },
                .shared => {
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(".cloneStrong()");
                },
                else => {
                    try self.writeLocalPlace(outer);
                    try self.w.writeAll(".cloneWeak()");
                },
            },
            .text, .deep => if (self.facts.unwrapViews(ty) == self.facts.types.string_view_id) {
                try self.w.writeAll("rig.String.of(.{ ");
                try self.writeLocalPlace(outer);
                try self.w.writeAll(" })");
            } else {
                try self.w.writeAll("rig.cloneValue(&(");
                try self.writeLocalPlace(outer);
                try self.w.writeAll("))");
            },
            // A generic `T` as each instance clones it (`rig.cloneAs`).
            .depends => {
                try self.w.writeAll("rig.cloneAs(");
                try self.emitTypeTy(self.facts.unwrapViews(ty));
                try self.w.writeAll(", ");
                try self.writeLocalPlace(outer);
                try self.w.writeAll(")");
            },
            .copy => try self.writeLocalPlace(outer),
            .no => return self.unsupported(node, "a clone of a value that moves"),
        }
    }

    /// `|?x|` / `|!x|`: the view of local `outer` a closure holds, of
    /// type `ty`, as `?x` / `!x` gives it: a pointer, or for a read
    /// view of plain data, the value.
    fn writeCapturedView(self: *Emitter, outer: *const Local, ty: TypeId) Error!void {
        // `|?f|` of a stack closure lends its environment.
        if (outer.stack_closure) if (self.facts.callableFn(ty)) |f| {
            try self.emitCallableTy("FnRef", f);
            return self.w.print(".of(@TypeOf({s}), &{s})", .{ outer.zig_name, outer.zig_name });
        };
        // A read view of a String is its bytes.
        if (outer.ty) |t| if (self.facts.viewsStringBytes(self.facts.unwrapViews(t), ty)) {
            try self.writeLocalPlace(outer);
            return self.w.writeAll(".bytes()");
        };
        const outer_is_view = if (outer.ty) |t| switch (self.facts.types.get(t)) {
            .read_view, .write_view => true,
            else => false,
        } else false;
        // `|?w|` of a `!{Shape}` holds the read view it lends, a value of
        // another Zig type (`rig.ApiView`).
        if (outer.ty) |t| if (self.facts.types.get(t) == .write_view and self.facts.objectView(t) != null and self.facts.types.get(ty) == .read_view) {
            try self.writeLocalPlace(outer);
            return self.w.writeAll(".read()");
        };
        // A read view, in a generic body, of what a write view points
        // at is that value's own read view (`rig.lend`).
        const outer_writes = if (outer.ty) |t| self.facts.types.get(t) == .write_view else false;
        if (outer_writes and self.facts.writeSliceElem(ty) == null and self.genericReadView(ty) != null) {
            return self.w.print("rig.lend({s})", .{outer.zig_name});
        }
        // A `![]T` is the slice itself; a view of a view passes it on.
        if (self.facts.writeSliceElem(ty) != null or (outer_is_view and (self.isPtrViewTy(ty) or !outer.is_ptr))) {
            return self.w.writeAll(outer.zig_name);
        }
        if (self.genericReadView(ty) != null) {
            try self.w.writeAll("rig.lend(");
            if (!outer.is_ptr) try self.w.writeAll("&");
            try self.w.writeAll(outer.zig_name);
            return self.w.writeAll(")");
        }
        if (self.isPtrViewTy(ty)) {
            if (!outer.is_ptr) try self.w.writeAll("&");
            return self.w.writeAll(outer.zig_name);
        }
        try self.writeLocalPlace(outer);
    }

    /// `*|captures, params| body` → a heap-allocated environment, erased
    /// into the runtime closure and boxed:
    ///
    ///     __rig_closure_N: {
    ///         const __rig_Env_N = struct { cap_x: T, pub fn __rig_invoke(...) R { ... } };
    ///         const __rig_env_N = rig.create(__rig_Env_N);
    ///         __rig_env_N.* = .{ .cap_x = ... };
    ///         break :__rig_closure_N rig.shared(rig.Closure(&.{ A }, R).init(__rig_Env_N, __rig_env_N));
    ///     }
    ///
    /// The environment is freed when the last strong handle drops.
    fn emitOwnedClosure(self: *Emitter, lambda: Sexp) Error!void {
        const f = self.fnType(self.typeOf(lambda)) orelse return self.unsupported(lambda, "an untyped closure");
        const caps = try self.captureInfo(ir.Lambda.captures(lambda));
        const id = self.nextId();
        const env = try self.fmt("__rig_Env_{d}", .{id});
        const env_ptr = try self.hiddenStorage(lambda, .closure_env, .owned, .{ .id = id });

        try self.w.print("__rig_closure_{d}: ", .{id});
        try self.openBrace();
        try self.writeIndent(self.indent);
        try self.w.print("const {s} = ", .{env});
        try self.emitClosureStruct(lambda, caps);
        try self.w.writeAll(";\n");
        try self.line("const {s} = rig.create({s});", .{ env_ptr, env });
        try self.writeIndent(self.indent);
        try self.w.print("{s}.* = .", .{env_ptr});
        try self.emitCaptureInit(caps);
        try self.w.writeAll(";\n");
        try self.writeIndent(self.indent);
        try self.w.print("break :__rig_closure_{d} rig.shared(", .{id});
        try self.emitCallableTy("Closure", f);
        try self.w.print(".init({s}, {s}));\n", .{ env, env_ptr });
        try self.closeBrace();
    }

    /// The runtime type behind a function type: `rig.Closure(&.{ A, B }, R)`
    /// for an owned closure `*fun(A, B) -> R`, `rig.FnRef(...)` for a
    /// callable view `?fun(A, B) -> R`.
    fn emitCallableTy(self: *Emitter, comptime runtime_type: []const u8, f: facts.FunctionType) Error!void {
        try self.w.writeAll("rig." ++ runtime_type ++ "(&.{");
        for (f.params, 0..) |p, i| {
            try self.w.writeAll(if (i == 0) " " else ", ");
            try self.emitTypeTy(p);
        }
        // A function that may fail with fields takes the slot they go in,
        // last, as a declared one does. A callable view of any fallible
        // function takes it, whatever its set: `FnRef` drops it for a
        // function that takes none, and a view typed `!E`, a set
        // parameter, is one type in every instance.
        const out = if (comptime std.mem.eql(u8, runtime_type, "FnRef"))
            self.facts.types.get(f.returns) == .fallible
        else
            self.failsWithFields(f.returns);
        if (out) try self.w.writeAll(if (f.params.len > 0) ", rig.ErrSlot" else " rig.ErrSlot");
        try self.w.writeAll(if (f.params.len > 0 or out) " }, " else "}, ");
        if (f.is_sub and f.returns == self.facts.types.void_id) try self.w.writeAll("void") else try self.emitTypeTy(f.returns);
        try self.w.writeAll(")");
    }

    /// `?{Shape}` or `!{Shape}`: `rig.ApiView(__rig_table_Shape, .read)`,
    /// or `.write`.
    fn emitObjectViewTy(self: *Emitter, ty: TypeId, o: facts.ApiObject) Error!void {
        try self.w.writeAll("rig.ApiView(");
        try self.writeTableName(o.api);
        try self.w.writeAll(if (self.facts.types.get(ty) == .write_view) ", .write, " else ", .read, ");
        try self.writeObjectBuiltins(o);
        try self.w.writeAll(")");
    }

    /// The built-in APIs an object's braces name after its API, as they
    /// spell them: `" + Owned + Print"`, or `""`.
    fn writeObjectBuiltins(self: *Emitter, o: facts.ApiObject) Error!void {
        try self.w.writeAll("\"");
        var it = o.builtins.iterator();
        while (it.next()) |b| try self.w.print(" + {s}", .{@tagName(b)});
        try self.w.writeAll("\"");
    }

    /// `e`, lent where a callable view of function type `fn_ty` is
    /// expected (`SemContext.callableOf`): a function, as
    /// `rig.FnRef(...).ofFn(f)`, or a viewed owned closure, as
    /// `.ofClosure(handle)`. A closure literal was hoisted
    /// (`hoistClosure`).
    fn emitLentCallable(self: *Emitter, e: Sexp, fn_ty: TypeId) Error!void {
        const f = self.facts.types.get(fn_ty).function;
        try self.emitCallableTy("FnRef", f);
        const ty = self.typeOf(e) orelse return self.unsupported(e, "an untyped callable");
        try self.w.writeAll(if (self.facts.ownedClosureFn(ty) != null) ".ofClosure(" else ".ofFn(");
        const saved = self.lending;
        defer self.lending = saved;
        self.lending = e;
        try self.emitExpr(e);
        try self.w.writeAll(")");
    }

    /// `?f` where `f` is a stack closure, a function value, or already a
    /// callable view: the `rig.FnRef` of function type `fn_ty`.
    fn emitFnRef(self: *Emitter, operand: Sexp, fn_ty: TypeId) Error!void {
        const ty = self.typeOf(operand) orelse return self.unsupported(operand, "an untyped callable");
        if (self.facts.callableFn(ty) != null) return self.emitExpr(operand);
        const f = self.facts.types.get(fn_ty).function;
        if (operand == .src) if (self.localOf(operand)) |local| if (local.stack_closure) {
            try self.emitCallableTy("FnRef", f);
            return self.w.print(".of(@TypeOf({s}), &{s})", .{ local.zig_name, local.zig_name });
        };
        try self.emitCallableTy("FnRef", f);
        try self.w.writeAll(".ofFn(");
        try self.emitExpr(operand);
        try self.w.writeAll(")");
    }

    /// A closure literal lent to the call being hoisted as a viewed
    /// callable: its environment `__rig_env_N`, dropped when the call's
    /// block ends if it owns what it captured, and the `rig.FnRef`
    /// lending it, the argument `h.name`.
    fn hoistClosure(self: *Emitter, h: Hoisted, fn_ty: TypeId) Error!void {
        const env = try self.hiddenStorage(h.node, .environment, .owned, .next);
        try self.writeIndent(self.indent);
        const owns = try self.emitStackClosure(env, h.node);
        try self.w.writeAll("\n");
        try self.poisonAtExit(env);
        // A closure called at most once takes what it owns of its
        // environment when it is called, and drops it there; otherwise
        // the environment drops it.
        if (owns) {
            if (self.facts.isOnceClosure(h.node)) {
                try self.line("defer if (!{s}.__rig_called) rig.dropFields(&{s});", .{ env, env });
            } else try self.line("defer rig.dropFields(&{s});", .{env});
        }
        try self.writeIndent(self.indent);
        try self.w.print("const {s} = ", .{h.name});
        try self.emitCallableTy("FnRef", self.facts.types.get(fn_ty).function);
        try self.w.print(".of(@TypeOf({s}), &{s});\n", .{ env, env });
        try self.hoisted.append(self.allocator, .{ .node = h.node, .name = h.name });
    }

    /// Whether a closure's body yields its value: not a `sub`'s, even a
    /// fallible one (`Void!`).
    fn lambdaYields(self: *Emitter, lambda: Sexp) bool {
        return self.facts.lambdaYields(lambda);
    }

    /// The value type a closure literal's body produces, or null.
    fn lambdaReturn(self: *Emitter, lambda: Sexp) ?TypeId {
        const f = self.fnType(self.typeOf(lambda)) orelse return null;
        return switch (self.facts.types.get(f.returns)) {
            .void, .unknown, .invalid, .noreturn => null,
            else => f.returns,
        };
    }

    // =========================================================================
    // Types
    // =========================================================================

    /// A type sema resolved.
    fn emitTypeTy(self: *Emitter, ty: TypeId) Error!void {
        const ctx = self.facts;
        // An error that carries fields is a `rig.ErrorValue`.
        if (!self.error_codes and self.isErrorValueTy(ty)) return self.w.writeAll("rig.ErrorValue");
        switch (ctx.types.get(ty)) {
            .void, .any_error, .bool, .string_view, .static, .string, .symbol, .int_literal, .float_literal, .int, .float => try self.emitBuiltinTy(ctx.types.get(ty)),
            .optional => |inner| {
                if (self.routesPayload(inner)) {
                    try self.w.writeAll("rig.Opt(");
                    try self.emitTypeTy(inner);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll("?");
                try self.emitTypeTy(inner);
            },
            // `T!` is any error; `T!E` the Zig set `E` names.
            .fallible => |f| {
                if (f.set == self.facts.types.any_error_id) try self.w.writeAll("anyerror!") else {
                    const saved = self.error_codes;
                    self.error_codes = true;
                    defer self.error_codes = saved;
                    try self.emitTypeTy(f.set);
                    try self.w.writeAll("!");
                }
                try self.emitTypeTy(f.ok);
            },
            .read_view => |inner| {
                if (ctx.callableFn(ty)) |f| return self.emitCallableTy("FnRef", f);
                if (ctx.objectView(ty)) |o| return self.emitObjectViewTy(ty, o);
                if (self.genericReadView(ty) != null) {
                    try self.w.writeAll("rig.ReadView(");
                    try self.emitTypeTy(inner);
                    return self.w.writeAll(")");
                }
                if (self.readViewIsPtr(inner)) return self.emitViewPtrTy(inner, .read);
                try self.emitTypeTy(inner);
            },
            .write_view => |inner| {
                if (ctx.objectView(ty)) |o| return self.emitObjectViewTy(ty, o);
                // A `![]T` is the Zig slice itself, writable.
                if (ctx.writeSliceElem(ty)) |elem| {
                    try self.w.writeAll("[]");
                    return self.emitTypeTy(elem);
                }
                try self.w.writeAll("*");
                try self.emitTypeTy(inner);
            },
            .shared, .weak => |inner| {
                // `*{Shape}` and `~{Shape}`: `rig.ApiShared(__rig_table_Shape,
                // "")`, `rig.ApiWeak(...)`.
                if (ctx.objectHandle(ty)) |o| {
                    try self.w.writeAll(if (ctx.types.get(ty) == .shared) "rig.ApiShared(" else "rig.ApiWeak(");
                    try self.writeTableName(o.api);
                    try self.w.writeAll(", ");
                    try self.writeObjectBuiltins(o);
                    return self.w.writeAll(")");
                }
                // `*Frozen[T]`: a `T` behind a handle counted atomically.
                if (ctx.frozenValue(inner)) |value| {
                    try self.w.writeAll("*rig.Frozen(");
                    try self.emitTypeTy(value);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll(if (ctx.types.get(ty) == .shared) "*rig.Shared(" else "rig.Weak(");
                switch (ctx.types.get(inner)) {
                    .function => |f| try self.emitCallableTy("Closure", f),
                    else => try self.emitTypeTy(inner),
                }
                try self.w.writeAll(")");
            },
            .slice => |s| {
                try self.w.writeAll("[]const ");
                try self.emitTypeTy(s.elem);
            },
            .array => |a| {
                try self.w.writeAll("[");
                try self.emitTypeTy(a.len);
                try self.w.writeAll("]");
                try self.emitTypeTy(a.elem);
            },
            .simd => |v| {
                if (v.elem == self.facts.types.bool_id) {
                    try self.w.writeAll("rig.Mask(");
                    try self.emitTypeTy(v.len);
                    return self.w.writeAll(")");
                }
                try self.w.writeAll("@Vector(");
                try self.emitTypeTy(v.len);
                try self.w.writeAll(", ");
                try self.emitTypeTy(v.elem);
                try self.w.writeAll(")");
            },
            // `Slot[n]`: the runtime's smallest unsigned that holds `n - 1`.
            .slot => |n| {
                try self.w.writeAll("rig.SlotOf(");
                try self.emitTypeTy(n);
                try self.w.writeAll(")");
            },
            // An array length or a generic type's value argument.
            .ct_value => |v| try self.w.print("{d}", .{v.int}),
            .ct_param => |sym_id| try self.writeTypeParam(sym_id),
            .nominal => |sym_id| try self.writeNominalName(sym_id),
            .imported_nominal => |in| {
                const foreign = ctx.foreign(in.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
                try self.writeModuleRef(in.module_id);
                try self.w.print(".{f}", .{ident(foreign.symbols.items[in.sym_id].name)});
            },
            .parameterized_nominal => |pn| {
                if (self.isSelfInstance(pn)) return self.w.writeAll("__rig_Self");
                // `^{Shape}`: `rig.ApiBox(__rig_table_Shape)`.
                if (pn.sym == ctx.box_sym_id) if (ctx.objectBox(ty)) |o| {
                    try self.w.writeAll("rig.ApiBox(");
                    try self.writeTableName(o.api);
                    try self.w.writeAll(", ");
                    try self.writeObjectBuiltins(o);
                    return self.w.writeAll(")");
                };
                if (pn.inline_len > 0) {
                    // `List[T, inline: n]`.
                    try self.w.writeAll("rig.InlineList(");
                    try self.emitTypeList(pn.args);
                    return self.w.print(", {d})", .{pn.inline_len});
                }
                try self.writeNominalName(pn.sym);
                try self.w.writeAll("(");
                try self.emitTypeArgs(ty, pn.sym, pn.args);
                try self.w.writeAll(")");
            },
            // A generic function's type parameter is its `comptime`
            // parameter; a generic type's, its function's.
            .type_var => |sym_id| try self.writeTypeParam(sym_id),
            .function => |f| {
                try self.w.writeAll("*const fn (");
                try self.emitTypeList(f.params);
                // A function that may fail with fields takes the slot they
                // go in, last (`emitCallableTy`).
                if (self.failsWithFields(f.returns)) try self.w.writeAll(if (f.params.len > 0) ", rig.ErrSlot" else "rig.ErrSlot");
                try self.w.writeAll(") ");
                try self.emitTypeTy(f.returns);
            },
            // Several results: a tuple of them, given by `return .{ a, b }`.
            .results => |parts| {
                try self.w.writeAll("@Tuple(&.{ ");
                try self.emitTypeList(parts);
                try self.w.writeAll(" })");
            },
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// A built-in type, which needs no type store.
    fn emitBuiltinTy(self: *Emitter, t: facts.Type) Error!void {
        switch (t) {
            .void => try self.w.writeAll("void"),
            .any_error => try self.w.writeAll("anyerror"),
            .bool => try self.w.writeAll("bool"),
            .string_view, .static => try self.w.writeAll("[]const u8"),
            .string => try self.w.writeAll("rig.String"),
            .symbol => {
                self.uses_symbols = true;
                try self.w.writeAll("__rig_sym.Symbol");
            },
            .int_literal => try self.w.writeAll(int_zig),
            .float_literal => try self.w.writeAll(float_zig),
            .int => |i| if (i.bits == 0) try self.w.writeAll(int_zig) else try self.w.print("{c}{d}", .{ @as(u8, if (i.signed) 'i' else 'u'), i.bits }),
            .float => |f| if (f.bits == 0) try self.w.writeAll(float_zig) else try self.w.print("f{d}", .{f.bits}),
            else => return self.unsupported(.nil, "a value of this type"),
        }
    }

    /// A type parameter, or a compile-time value parameter: a generic
    /// function's `comptime` parameter, or a generic type's function's.
    fn writeTypeParam(self: *Emitter, sym: SymbolId) Error!void {
        // An associated type is named through its base: by the witness of
        // the bound that declares it (`W_S_Source.Item`), or, for an
        // iterator's item, by what its `next` gives (`rig.IterItem(I)`).
        if (self.facts.symbols.items[sym].assoc_of) |of| switch (of.api) {
            .user => |u| return self.w.print("{s}.{f}", .{ try self.witnessParamName(of.base, u.via), ident(of.name) }),
            .iter => {
                try self.w.writeAll("rig.IterItem(");
                try self.writeTypeParam(of.base);
                return self.w.writeAll(")");
            },
        };
        if (self.localBySym(sym)) |local| return self.w.writeAll(local.zig_name);
        try self.w.print("{f}", .{ident(self.facts.symbols.items[sym].name)});
    }

    /// `A, B, C`.
    fn emitTypeList(self: *Emitter, tys: []const TypeId) Error!void {
        for (tys, 0..) |t, i| {
            if (i > 0) try self.w.writeAll(", ");
            try self.emitTypeTy(t);
        }
    }

    /// A user nominal, or a runtime one (`List` → `rig.List`), or another
    /// module's generic type through its proxy (`lib.Wrap`).
    fn writeNominalName(self: *Emitter, sym: SymbolId) Error!void {
        const s = self.facts.symbols.items[sym];
        if (self.facts.isBuiltinGeneric(sym) or self.facts.isBuiltinEnum(sym) or sym == self.facts.printer_sym_id or sym == self.facts.hasher_sym_id) {
            // The runtime's `Box(T)` is `^T`.
            return self.w.print("rig.{s}", .{if (sym == self.facts.box_sym_id) "Box" else s.name});
        }
        if (facts.syntax.isProxy(s)) {
            const foreign = self.facts.foreign(s.from.module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
            try self.writeModuleRef(s.from.module_id);
            return self.w.print(".{f}", .{ident(foreign.symbols.items[s.from.sym].name)});
        }
        try self.writeModuleName(s.name);
    }

    /// Another module, by the name this one imports it as, or, for a
    /// module reached only through an import, by its file.
    fn writeModuleRef(self: *Emitter, module_id: u32) Error!void {
        for (0..self.facts.importCount()) |i| {
            const imp = self.facts.importAt(i);
            if (imp.module_id == module_id) return self.writeModuleZig(module_id);
        }
        const foreign = self.facts.foreign(module_id) orelse return self.unsupported(.nil, "a type from an unloaded module");
        try self.w.print("@import(\"{s}\")", .{foreign.zig_file});
    }

    /// The generic type being emitted, applied to its own parameters:
    /// `__rig_Self` inside its body.
    fn isSelfInstance(self: *Emitter, pn: facts.ParamNominal) bool {
        const n = self.nominal orelse return false;
        if (pn.sym != n.sym) return false;
        const params = self.facts.symbols.items[n.sym].type_params orelse return false;
        if (params.len != pn.args.len) return false;
        for (params, pn.args) |p, a| switch (self.facts.types.get(a)) {
            .type_var, .ct_param => |v| if (v != p) return false,
            else => return false,
        };
        return true;
    }

    // -------------------------------------------------------------------------
    // Type queries (all from sema's facts)
    // -------------------------------------------------------------------------

    /// The type sema recorded for an expression. Poison types count as
    /// unknown.
    fn typeOf(self: *Emitter, expr: Sexp) ?TypeId {
        const ty = self.facts.typeOf(expr) orelse return null;
        return self.known(ty);
    }

    fn symType(self: *Emitter, sym: SymbolId) ?TypeId {
        return self.known(self.facts.symbols.items[sym].ty);
    }

    fn known(self: *Emitter, ty: TypeId) ?TypeId {
        if (ty == self.facts.types.unknown_id or ty == self.facts.types.invalid_id) return null;
        return ty;
    }

    /// `storage.fnType`.
    fn fnType(self: *Emitter, ty: ?TypeId) ?facts.FunctionType {
        return self.facts.fnType(ty);
    }

    fn peelViews(self: *Emitter, ty: TypeId) TypeId {
        return self.facts.unwrapViews(ty);
    }

    /// `storage.variantPayload`.
    fn variantPayload(self: *Emitter, enum_ty: TypeId, vname: []const u8) ?[]const facts.Field {
        return self.facts.variantPayload(enum_ty, vname);
    }

    /// How binding `sym` holds its value (`Symbol.hold`, recorded by the
    /// storage plan), or null for one that owns nothing to drop. A
    /// binding that holds one gets `var` storage and a drop guard, owned
    /// `as` and payload bindings, and an owned closure environment; the
    /// kind picks its drop call.
    fn holdOf(self: *Emitter, sym: SymbolId) ?ResourceKind {
        return self.facts.symbols.items[sym].hold;
    }

    /// How hidden storage holding the value of `e`, or a discard of it,
    /// drops it (`storage.dropKind`), or null when it owns nothing.
    fn dropKind(self: *Emitter, e: Sexp) Error!?ResourceKind {
        return self.need(self.facts.dropKind(e), e);
    }

    fn isBuiltinInstance(self: *Emitter, ty: TypeId, sym_id: SymbolId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .parameterized_nominal => |pn| pn.sym == sym_id,
            else => false,
        };
    }

    /// A Cell holding a List, reached by value, view, or shared handle.
    fn isCellListTy(self: *Emitter, ty: TypeId) bool {
        const cell = switch (self.facts.types.get(self.facts.unwrapReadAccess(ty))) {
            .parameterized_nominal => |pn| if (pn.sym == self.facts.cell_sym_id and pn.args.len == 1) pn.args[0] else return false,
            else => return false,
        };
        return self.isListTy(cell);
    }

    fn isListTy(self: *Emitter, ty: TypeId) bool {
        return self.isBuiltinInstance(ty, self.facts.list_sym_id);
    }

    /// Whether a value of `ty` is a shared handle, or a view of one: a
    /// pointer to it is a pointer to a pointer, which Zig does not reach
    /// a field or method through.
    fn reachesHandle(self: *Emitter, ty: ?TypeId) bool {
        return self.facts.types.get(self.peelViews(ty orelse return false)) == .shared;
    }

    /// `.*` for each pointer a value of `ty`, a shared handle or a view
    /// of one, is above the handle: Zig reaches a field through a
    /// pointer to the handle's box, never through one to the handle.
    fn derefToHandle(self: *Emitter, ty: ?TypeId) Error!void {
        var t = ty orelse return;
        if (!self.reachesHandle(t)) return;
        while (true) switch (self.facts.types.get(t)) {
            .read_view, .write_view => |inner| {
                if (self.isPtrViewTy(t)) try self.w.writeAll(".*");
                t = inner;
            },
            else => return,
        };
    }

    /// The element a `for` over a value of `ty` walks: a List's, an
    /// array's, or a slice's, through views; null for any other.
    fn loopElem(self: *Emitter, ty: TypeId) ?TypeId {
        const t = self.peelViews(ty);
        return switch (self.facts.types.get(t)) {
            .array => |a| a.elem,
            .slice => |sl| sl.elem,
            .parameterized_nominal => |pn| if (self.isListTy(t) or self.facts.tableElem(t) != null) pn.args[0] else null,
            else => null,
        };
    }

    fn isStructLike(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(self.peelViews(ty))) {
            .nominal, .parameterized_nominal, .imported_nominal => true,
            else => false,
        };
    }

    /// Whether member access on `ty` reaches, through shared handles
    /// (`*T`, `*Frozen[T]`) and boxes, a value `hasLen` holds of: its
    /// `.len` is read there (`writeReach`).
    fn hasLenReached(self: *Emitter, ty: TypeId) bool {
        return self.hasLen(self.facts.unwrapAccess(ty));
    }

    fn hasLen(self: *Emitter, ty: TypeId) bool {
        const peeled = self.peelViews(ty);
        return switch (self.facts.types.get(peeled)) {
            .array, .slice, .string_view, .static => true,
            else => self.isListTy(peeled) or self.facts.tableElem(peeled) != null,
        };
    }

    /// Numbers, Bool, `?String`, functions, and optionals of them: bindings
    /// of these types are annotated, since a literal or branch value alone
    /// has no runtime type, and a function name alone is a function body,
    /// not a pointer to one.
    fn isPlainTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(ty)) {
            .int, .float, .int_literal, .float_literal, .bool, .string_view, .static, .function, .slot => true,
            .optional => |inner| self.isPlainTy(inner),
            else => false,
        };
    }

    /// An error set (local or imported) or any error: its members are
    /// spelled `error.name`.
    fn isErrorSetTy(self: *Emitter, ty: TypeId) bool {
        const t = self.peelViews(ty);
        return self.facts.types.get(t) == .any_error or self.facts.isErrorSet(t) or self.facts.isSetParam(t);
    }

    /// The type an integer literal takes in arithmetic of `e`'s type: a
    /// float type (a `Float` literal is a `Float`) or a type parameter.
    fn literalTypeOf(self: *Emitter, e: Sexp) ?TypeId {
        const ty = self.typeOf(e) orelse return null;
        return switch (self.facts.types.get(ty)) {
            .float, .type_var => ty,
            .float_literal => self.facts.types.float_id,
            else => null,
        };
    }

    /// `pre(left, right)post`. A payload variant literal (`.circle(r: 1)`)
    /// is spelled with its enum type, which the other operand gave it.
    fn emitCall2(self: *Emitter, pre: []const u8, operands: [2]Sexp, post: []const u8) Error!void {
        try self.w.writeAll(pre);
        for (operands, 0..) |o, i| {
            if (i > 0) try self.w.writeAll(", ");
            const variant = o.isKind(.call) and ir.Call.callee(o).isKind(.enum_lit);
            const ty = if (variant) self.typeOf(o) else null;
            if (ty) |t| try self.writeAsOpen(t);
            try self.emitExpr(o);
            if (ty != null) try self.w.writeAll(")");
        }
        try self.w.writeAll(post);
    }

    /// Whether `a == b` compares with `rig.eql` rather than Zig's `==`:
    /// an operand is not a scalar (a `?String`, a struct, a payload enum, an
    /// array or slice, an optional of one, an optional error, or a type
    /// parameter's value). `none` compares with any optional by `==`.
    fn comparesStructurally(self: *Emitter, operands: [2]Sexp) bool {
        for (operands) |o| if (self.isNoneLeaf(o)) return false;
        for (operands) |o| {
            const ty = self.typeOf(o) orelse continue;
            const t = self.peelViews(ty);
            // A type with its own `==` compares by it (`rig.eql`).
            if (self.facts.ownApiOf(t, .Eq) != null) return true;
            const scalar = switch (self.facts.types.get(t)) {
                .optional => |inner| self.isScalarTy(inner) and !self.isErrorSetTy(inner),
                // A vector's `==` is Zig's, lane by lane.
                .simd => true,
                else => self.isScalarTy(t),
            };
            if (!scalar) return true;
        }
        return false;
    }

    /// An operand whose value is an enum with payloads, or an optional
    /// of one.
    fn isPayloadEnumOperand(self: *Emitter, e: Sexp) bool {
        const ty = self.typeOf(e) orelse return false;
        const t = switch (self.facts.types.get(self.peelViews(ty))) {
            .optional => |inner| inner,
            else => self.peelViews(ty),
        };
        return self.hasPayloadVariants(t);
    }

    /// A number, Bool, plain enum, or error: Zig's `==` compares it.
    fn isScalarTy(self: *Emitter, ty: TypeId) bool {
        return switch (self.facts.types.get(ty)) {
            .int, .float, .bool, .symbol, .int_literal, .float_literal, .any_error, .slot => true,
            .nominal, .imported_nominal => self.facts.isPlainEnum(ty) or self.facts.isErrorSet(ty),
            else => false,
        };
    }

    const OrderOperator = struct {
        /// Strings or byte slices; otherwise a type parameter's or a
        /// plain enum's values.
        bytes: bool,
        /// The `std.math.CompareOperator` name.
        op: []const u8,
        /// What tests the `std.math.Order` of two byte strings.
        test_: []const u8,
    };

    /// How `a < b` (`<=`, `>`, `>=`) lowers when Zig's operator does not
    /// order its operands: text and byte slices, a type parameter's
    /// values, and a plain enum's, which order by the variants' values
    /// (the only enums sema lets an ordering take). Null for numbers and
    /// vectors, whatever their compile-time arguments (`Simd[U8, n]`
    /// orders lane by lane with Zig's `<`).
    fn orderOperator(self: *Emitter, kind: Tag, operands: [2]Sexp) ?OrderOperator {
        var bytes = false;
        var values = false;
        for (operands) |o| {
            const ty = self.typeOf(o) orelse continue;
            const t = self.peelViews(ty);
            switch (self.facts.types.get(t)) {
                .string_view, .static => bytes = true,
                // A byte slice orders by its bytes; any other ordered
                // slice element by element (`rig.compare`).
                .slice => |sl| if (self.facts.types.get(sl.elem) == .int and self.facts.types.get(sl.elem).int.bits == 8 and !self.facts.types.get(sl.elem).int.signed) {
                    bytes = true;
                } else {
                    values = true;
                },
                // A frozen value's handle orders by what it reaches.
                .type_var, .nominal, .imported_nominal, .parameterized_nominal, .bool, .string, .optional, .array, .shared => values = true,
                else => {},
            }
        }
        if (!bytes and !values) return null;
        return switch (kind) {
            .@"<" => .{ .bytes = bytes, .op = "lt", .test_ = ") == .lt" },
            .@"<=" => .{ .bytes = bytes, .op = "lte", .test_ = ") != .gt" },
            .@">" => .{ .bytes = bytes, .op = "gt", .test_ = ") == .gt" },
            .@">=" => .{ .bytes = bytes, .op = "gte", .test_ = ") != .lt" },
            else => null,
        };
    }

    /// The builtin `left op right` lowers to for `/` and `%`, or null for
    /// float `/`, which is ordinary division. Integer `/` truncates toward
    /// zero (`@divTrunc`), and a type parameter's values divide as their
    /// instance does (`rig.div`). `%` is the remainder with the dividend's
    /// sign (`rig.rem`), for integers and floats alike.
    fn divBuiltin(self: *Emitter, op: Tag, left: Sexp, right: Sexp) ?[]const u8 {
        if (op == .@"%") return "rig.rem";
        if (self.literal_ty) |t| return if (self.facts.types.get(t) == .type_var) "rig.div" else null;
        var builtin: []const u8 = "@divTrunc";
        for ([2]Sexp{ left, right }) |e| {
            const ty = self.typeOf(e) orelse continue;
            switch (self.facts.types.get(self.peelViews(ty))) {
                .float, .float_literal => return null,
                .type_var => builtin = "rig.div",
                else => {},
            }
        }
        return builtin;
    }

    // =========================================================================
    // Output helpers
    // =========================================================================

    fn srcText(self: *Emitter, sexp: Sexp) []const u8 {
        return rig.leafText(self.source, sexp.src);
    }

    fn writeIndent(self: *Emitter, depth: u32) Error!void {
        for (0..depth) |_| try self.w.writeAll("    ");
    }

    /// One indented line.
    fn line(self: *Emitter, comptime f: []const u8, args: anytype) Error!void {
        try self.writeIndent(self.indent);
        try self.w.print(f ++ "\n", args);
    }

    /// `defer rig.poison(&name);` for the hidden `var` `name` (`poison`),
    /// written before its drop's `defer`, so it runs after the drop.
    fn poisonAtExit(self: *Emitter, name: []const u8) Error!void {
        if (self.poison) try self.line("defer rig.poison(&{s});", .{name});
    }

    /// Report a construct the emitter cannot lower. Sema is responsible
    /// for rejecting it with a proper diagnostic; reaching this is a
    /// compiler bug.
    // =========================================================================
    // Units (docs/internals/INTERNALS.md, "Proven checks")
    // =========================================================================

    /// Start writing the code of the unit `node` is the root of
    /// (`facts.unitRootKind`), unless it is the one being written; the
    /// caller passes the result to `leaveUnit`.
    fn enterUnit(self: *Emitter, node: Sexp) Error!bool {
        if (self.facts.unitRootKind(node) == null) return false;
        const key = node.list.id;
        if (self.units.items.len > 0 and self.units.getLast() == key) return false;
        try self.units.append(self.allocator, key);
        // A paused unit is taken up again, not written anew.
        const resumed = self.paused.swapRemove(key);
        if (self.unit_trace) |t| try t.append(self.allocator, if (resumed) .{ .@"resume" = key } else .{ .enter = key });
        return true;
    }

    /// Leave the unit `root` when it is the one being written.
    fn endUnit(self: *Emitter, root: Sexp) Error!void {
        if (self.units.items.len > 0 and self.units.getLast() == root.list.id) self.leaveUnit(true);
    }

    fn leaveUnit(self: *Emitter, entered: bool) void {
        if (!entered) return;
        const key = self.units.pop().?;
        if (self.unit_trace) |t| t.append(self.allocator, .{ .exit = key }) catch {};
    }

    /// Stop writing the code of a statement `match`'s selection while an
    /// arm runs, which comes after it; `resumeUnit` takes it up again.
    fn pauseUnit(self: *Emitter, root: Sexp) Error!bool {
        if (root != .list or self.units.items.len == 0 or self.units.getLast() != root.list.id) return false;
        const key = self.units.pop().?;
        try self.paused.put(self.allocator, key, {});
        if (self.unit_trace) |t| try t.append(self.allocator, .{ .pause = key });
        return true;
    }

    fn resumeUnit(self: *Emitter, root: Sexp, paused: bool) Error!void {
        if (paused) _ = try self.enterUnit(root);
    }

    /// The assertion that keeps the proof pass honest: emit writes `node`
    /// inside the code of the unit that holds it, so no hoist carries a
    /// check, a write, or a value into another unit's code. On in every
    /// debug build of the compiler.
    fn inUnit(self: *Emitter, node: Sexp) Error!void {
        if (!check_units) return;
        const want = self.facts.unitOf(node) orelse return;
        const have: ?facts.NodeKey = if (self.units.items.len > 0) self.units.getLast() else null;
        if (have != want) return self.unsupported(node, "code outside the unit that holds it (docs/internals/INTERNALS.md, \"Proven checks\")");
    }

    /// The tests of `node` known to pass, which emit omits.
    fn provenOf(self: *Emitter, node: Sexp) facts.Proven {
        if (self.no_proofs) return .{};
        return self.facts.provenOf(node);
    }

    /// The tests of `node` known to pass while a flag holds, and the
    /// flag's Zig name: null unless the flag is written (`emitFlag`).
    fn provenIf(self: *Emitter, node: Sexp) ?struct { tests: facts.Proven, flag: []const u8 } {
        if (self.no_proofs) return null;
        const p = self.facts.provenIfOf(node) orelse return null;
        return .{ .tests = p.tests, .flag = self.flag_names.get(p.flag) orelse return null };
    }

    /// The flag made before statement `stmt` (docs/internals/INTERNALS.md,
    /// "Flags"), when the proof pass made one: its tests, each of a
    /// binding or a length as the statement starts, and together.
    ///
    ///     const __rig_ok_7 = rig.okNonneg(i) and rig.okBelow(i, 5, self.words.len); _ = &__rig_ok_7;
    ///
    /// A flag whose bindings emit does not hold by name is not written,
    /// and the tests it would prove are made.
    fn emitFlag(self: *Emitter, stmt: Sexp) Error!void {
        if (self.no_proofs or stmt != .list) return;
        const tests = self.facts.flagOf(stmt) orelse return;
        for (tests) |t| switch (t) {
            .nonneg => |i| if (!self.flagReads(i)) return,
            .below => |b| if (!self.flagReads(b.i) or !self.flagReads(b.s.root)) return,
        };
        const name = try self.fmt("__rig_ok_{d}", .{self.nextId()});
        try self.w.print("const {s} = ", .{name});
        for (tests, 0..) |t, n| {
            if (n > 0) try self.w.writeAll(" and ");
            switch (t) {
                .nonneg => |i| {
                    try self.w.writeAll("rig.okNonneg(");
                    try self.writeFlagRead(i);
                    try self.w.writeAll(")");
                },
                .below => |b| {
                    try self.w.writeAll("rig.okBelow(");
                    try self.writeFlagRead(b.i);
                    try self.w.print(", {d}, ", .{b.k});
                    try self.writeFlagRead(b.s.root);
                    for (b.s.fields) |f| try self.w.print(".{f}", .{ident(f)});
                    try self.w.writeAll(".len)");
                },
            }
        }
        try self.w.print("; _ = &{s}; ", .{name});
        if (self.scopes.items.len == 0) try self.pushScope();
        try self.scopes.items[self.scopes.items.len - 1].flags.append(self.allocator, stmt.list.id);
        try self.flag_names.put(self.allocator, stmt.list.id, name);
    }

    /// Whether a flag can read binding `sym` by its Zig name: a local
    /// emit holds, not as a closure's capture.
    fn flagReads(self: *Emitter, sym: SymbolId) bool {
        const local = self.localBySym(sym) orelse return false;
        return isPlainIdent(local.zig_name);
    }

    /// Binding `sym` as a flag's test reads it.
    fn writeFlagRead(self: *Emitter, sym: SymbolId) Error!void {
        const local = self.localBySym(sym).?;
        try self.w.writeAll(local.zig_name);
        if (local.is_ptr and self.facts.symbols.items[sym].ty == self.facts.types.int_id) try self.w.writeAll(".*");
    }

    fn unsupported(self: *Emitter, node: Sexp, what: []const u8) Error {
        const lc = diag.lineCol(self.source, self.facts.startOf(if (node == .nil) self.stmt else node));
        std.debug.print("{d}:{d}: internal error: cannot emit {s} (sema should have rejected it)\n", .{ lc.line, lc.col, what });
        return error.Unsupported;
    }
};

// =============================================================================
// Usage scan
// =============================================================================

/// One walk over the module that records, per symbol, what the emitter
/// needs before it writes a binding: whether it is used or consumed, and
/// which match bindings view which scrutinee.
const Scan = struct {
    e: *Emitter,

    fn put(s: *Scan, set: *std.AutoHashMapUnmanaged(SymbolId, void), sym: SymbolId) Error!void {
        try set.put(s.e.allocator, sym, {});
    }

    fn walk(s: *Scan, sexp: Sexp) Error!void {
        switch (sexp) {
            .src => |leaf| {
                const sym = s.e.facts.symbolOf(sexp) orelse return;
                if (s.e.facts.symbols.items[sym].decl_pos != leaf.pos) try s.put(&s.e.usage.used, sym);
                return;
            },
            .list => {},
            else => return,
        }
        // A group (parameters, a function type's parameters) names
        // what it holds, too.
        const head = sexp.kind() orelse {
            for (sexp.items()) |c| try s.walk(c);
            return;
        };
        switch (head) {
            .cap_clone, .cap_weak, .cap_move, .cap_read, .cap_write => {
                const cap = s.e.facts.symbolOf(ir.get(sexp, .name)) orelse return;
                try s.put(&s.e.usage.used, s.e.facts.symbols.items[cap].origin);
                return;
            },
            // A compile-time function is not emitted.
            .fun => if (rig.isCtFun(sexp)) return,
            else => {},
        }
        for (rig.children(sexp)) |c| try s.walk(c);
    }
};

// =============================================================================
// Free helpers
// =============================================================================

/// Zig spellings of Rig's default numeric types.
const int_zig = "i64";
const float_zig = "f64";

/// Formats a Rig identifier as a Zig identifier (`rig.writeZigIdent`).
const Ident = struct {
    name: []const u8,
    spelling: rig.ZigSpelling = .rig,

    pub fn format(self: Ident, w: *Writer) Writer.Error!void {
        try rig.writeZigIdent(w, self.name, self.spelling);
    }
};

fn ident(name: []const u8) Ident {
    return .{ .name = name };
}

/// A name another file declares exactly so: a function of a standard
/// library Zig file (`rig.ZigSpelling.exact`).
fn exactIdent(name: []const u8) Ident {
    return .{ .name = name, .spelling = .exact };
}

/// The Zig name of member `name` of error set `set`, declared in the
/// module `owner`: `@"Set.name"`, or `@"mod.Set.name"` for a module other
/// than the root. Zig's errors share one namespace, so each carries its
/// set and module; `rig.print` shows the last two parts.
fn writeErrorName(w: *Writer, owner: Facts, set: []const u8, name: []const u8) Error!void {
    const module = nameModule(owner);
    if (module.len == 0) return w.print("@\"{s}.{s}\"", .{ set, name });
    try w.print("@\"{s}.{s}.{s}\"", .{ module, set, name });
}

/// The module a name the emitter writes carries (an error's, a type's
/// `__rig_name`): its own, or none for the root.
fn nameModule(ctx: Facts) []const u8 {
    return if (ctx.is_root) "" else ctx.name;
}

/// A literal default value: a number, a string, `true` / `false`,
/// `none`, `.variant`, or a negated number.
fn isDefaultLiteralNode(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => |s| blk: {
            const t = rig.leafText(source, s);
            break :blk isLiteralText(t) or std.mem.eql(u8, t, "none");
        },
        .list => e.isKind(.enum_lit) or (e.isKind(.neg) and ir.Neg.operand(e) == .src),
        else => false,
    };
}

/// A default argument value: a literal, written from the source of the
/// module that declares it.
fn writeLiteral(w: *Writer, source: []const u8, e: Sexp) Error!void {
    switch (e) {
        .src => |s| {
            const t = rig.leafText(source, s);
            if (std.mem.eql(u8, t, "none")) return w.writeAll("null");
            if (t[0] == '\'') return writeSingleQuoted(w, t);
            // Zig has no `.5`.
            if (t[0] == '.') try w.writeAll("0");
            try w.writeAll(t);
        },
        // `.red`: the variant's name, never read as a literal (`.none`
        // names a variant, not the absent value).
        .list => if (e.isKind(.enum_lit)) {
            try w.print(".{f}", .{ident(rig.leafText(source, ir.EnumLit.name(e).src))});
        } else {
            // `-1`: the sign, then the number.
            try w.writeAll("-");
            try writeLiteral(w, source, ir.Neg.operand(e));
        },
        else => {},
    }
}

/// A Rig single-quoted string as a Zig string literal, of the bytes
/// `facts.syntax.SingleQuoted` reads.
fn writeSingleQuoted(w: *Writer, lit: []const u8) Error!void {
    try w.writeAll("\"");
    var it = facts.syntax.SingleQuoted.init(lit);
    while (it.next()) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeAll("\"");
}

fn isPlainIdent(name: []const u8) bool {
    return name.len > 0 and name[0] != '@' and std.mem.findScalar(u8, name, '.') == null;
}

/// Whether Zig could evaluate `e` at compile time. A positive list: a
/// literal, a name of a constant (a module-level binding, a compile-time
/// parameter, a function or a type), a constructor or variant, and an
/// operator, index, field, propagation, `??`, `catch`, ternary, or `match`
/// whose parts all are. Any other form (a call, a lend, a move, a clone,
/// a closure, an extern variable, a form added later) is not.
fn isZigComptimeIn(em: *Emitter, e: Sexp, depth: u8) bool {
    if (depth > 32) return true;
    switch (e) {
        .src => {
            const t = em.srcText(e);
            if (isLiteralText(t) or std.mem.eql(u8, t, "none")) return true;
            // A label or member name, which names no symbol.
            const sym = em.facts.symbolOf(e) orelse return true;
            const sd = em.facts.symbols.items[sym];
            return switch (sd.kind) {
                // A module-level binding is a Zig `pub const`, known at
                // compile time whatever it holds.
                .local => em.facts.isModuleLevel(sym) or sd.flags.comptime_known,
                .param, .capture => sd.flags.comptime_known,
                .function, .type_alias, .generic_type, .generic_param, .nominal_type, .module => true,
                else => false,
            };
        },
        .list => {
            const h = e.kind() orelse return false;
            switch (h) {
                .call => {
                    // A constructor or variant of constant arguments is
                    // constant; a function call is not. A member callee
                    // without a type of its own names a variant or a
                    // type of another module (`emitCallPlain`).
                    const callee = em.facts.calleeOf(e);
                    const ctor = callee.isKind(.enum_lit) or
                        (callee == .src and if (em.facts.symbolOf(callee)) |id| em.isTypeSym(id) else false) or
                        (callee.isKind(.member) and em.facts.typeOf(callee) == null);
                    if (!ctor) return false;
                    for (ir.Call.args(e)) |a| if (!isZigComptimeIn(em, argValue(a), depth + 1)) return false;
                    return true;
                },
                .array, .array_fill, .index, .member, .inst, .enum_lit, .builtin, .@"..", .@"if", .match, .block,
                .propagate, .propagate_none, .@"catch", .@"??", .neg, .not, .@"and", .@"or",
                .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^",
                .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => {
                    for (rig.children(e)) |c| {
                        if (c == .tag or c == .nil) continue;
                        if (!isZigComptimeIn(em, c, depth + 1)) return false;
                    }
                    return true;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

fn isIntZeroText(t: []const u8) bool {
    if (!facts.syntax.isIntLiteralText(t)) return false;
    const v = std.fmt.parseInt(Wide, t, 0) catch return false;
    return v == 0;
}

const isLiteralText = facts.syntax.isLiteralText;

/// An integer or float literal.
fn isNumberText(t: []const u8) bool {
    return facts.syntax.isIntLiteralText(t) or facts.syntax.isFloatLiteralText(t);
}

/// The runtime's name for the tests of an index or byte access known to
/// pass (`rig.Proven`), or null when none is.
fn provenTests(p: facts.Proven) ?[]const u8 {
    if (p.lower and p.upper) return "both";
    if (p.lower) return "lower";
    if (p.upper) return "upper";
    return null;
}

fn isNonNegativeIntLiteral(source: []const u8, s: Sexp) bool {
    if (s != .src) return false;
    const t = rig.leafText(source, s.src);
    for (t) |c| if (!std.ascii.isDigit(c) and c != '_') return false;
    return t.len > 0;
}

const lentPlace = facts.syntax.lentPlace;

/// Whether `e` moves a compound value, `<(a if c else b)` or `<(?t)`,
/// emitted as that value, which a postfix after it would not reach
/// whole: anything but a name, a field, an element, or a call.
fn movesCompound(e: Sexp) bool {
    if (!e.isKind(.move)) return false;
    const o = ir.Move.operand(e);
    if (o != .list) return false;
    return !(o.isKind(.member) or o.isKind(.index) or o.isKind(.call));
}

const argValue = facts.syntax.argValue;

const contains = facts.syntax.contains;

/// The same IR node: the same leaf, or the same list.
fn sameNode(a: Sexp, b: Sexp) bool {
    return switch (a) {
        .src => |s| b == .src and b.src.pos == s.pos,
        .list => b == .list and a.items().ptr == b.items().ptr,
        else => false,
    };
}

/// What `sameNode` compares a node by: a leaf's position, or a list's
/// items. Two nodes are the same exactly when their keys are equal.
const PartKey = struct { leaf: bool, at: usize };

fn partKey(n: Sexp) ?PartKey {
    return switch (n) {
        .src => |s| .{ .leaf = true, .at = s.pos },
        .list => .{ .leaf = false, .at = @intFromPtr(n.items().ptr) },
        else => null,
    };
}

fn isTerminatingStmt(s: Sexp) bool {
    const h = s.kind() orelse return false;
    return h == .@"return" or h == .@"break" or h == .@"continue" or h == .panic;
}

// Emitted code never writes through a const pointer or into const
// storage: a Cell lives only behind a shared handle, on the heap, and a
// value that holds one is viewed through a mutable pointer
// (`emitViewPtrTy`), so no cast is ever
// needed, and a write a missed site would make through a `*const T` is a
// Zig compile error rather than undefined behavior. Neither the emitter
// nor the runtime casts constness away, except the runtime's `FnRef.ofFn`,
// which erases a function pointer into a context no code writes through.
test "emit and the runtime cast no constness away" {
    const cast = "@const" ++ "Cast(";
    try std.testing.expectEqual(0, std.mem.count(u8, @embedFile("emit.zig"), cast));
    try std.testing.expectEqual(1, std.mem.count(u8, runtime_source, cast));
    const of_fn = std.mem.indexOf(u8, runtime_source, "pub fn ofFn(").?;
    const end = std.mem.indexOfPos(u8, runtime_source, of_fn, "\n        }\n").?;
    try std.testing.expect(std.mem.indexOf(u8, runtime_source[of_fn..end], cast) != null);
}

/// How many levels of optional `ty` has.
fn optionalDepth(types: *const facts.TypeStore, ty: TypeId) u32 {
    var n: u32 = 0;
    var t = ty;
    while (types.get(t) == .optional) : (n += 1) t = types.get(t).optional;
    return n;
}
