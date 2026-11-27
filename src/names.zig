//! The names the compiler writes and the runtime reads, each spelled
//! once here: how a Rig name is spelled in Zig, the declarations emitted
//! code makes for the runtime to find by name, and the runtime's face,
//! every declaration of the runtime that emitted code names, as one
//! closed list. `bin/rig` writes this file verbatim beside the runtime
//! as `rig/names.zig`, which the runtime imports; the compiler imports it
//! as source. Only the compiler uses the closed list, so only it reads
//! `runtime.zig` from here; the file imports nothing that is not written
//! beside the runtime, since Zig loads every file a file imports.

const std = @import("std");
const runtime = @import("runtime.zig");

/// The mark the Zig spelling of a Rig name the emitted Zig cannot keep
/// (`std`, `rig`, `debug`) ends with: `@"rig'"` (`rig.writeZigIdent` in
/// the compiler, which a test in main.zig holds to it). No Rig name
/// contains it.
pub const renamed_mark = "'";

/// The Rig name of a Zig name the emitter wrote: the name without its
/// `renamed_mark`.
pub fn rigName(zig: []const u8) []const u8 {
    return if (zig.len > 1 and zig[zig.len - 1] == renamed_mark[0]) zig[0 .. zig.len - 1] else zig;
}

/// The declarations emitted code makes that the runtime finds by name,
/// with `@hasDecl` or `@hasField`: in the root module (`config`,
/// `program`, `site_programs`, `sites_of`, `unit`), in a module
/// (`sites`), and in a type, its markers and glue. Both sides spell them
/// through `decl`, so a test for one cannot miss the other's spelling.
pub const Decl = enum {
    config, drop, name, none_field, own_eq, own_hash, own_order,
    own_print, program, repr, site_programs, sites, sites_of,
    strict_optional, symbol, synced, trace, unit,
};

/// The spelling of declaration `d`: `__rig_NAME`. Inline, so a spelling
/// joined to the text around it is one constant, as `rt`'s is.
pub inline fn decl(comptime d: Decl) *const [6 + @tagName(d).len:0]u8 {
    return "__rig_" ++ @tagName(d);
}

/// The runtime declarations emitted code may name, each spelled as the
/// runtime declares it.
pub const Name = enum {
    actor, actorCall, actorSpawn, actorSupervised, addIf, addProven, afterArm,
    ApiBox, ApiHolding, ApiShared, ApiView, ApiWeak, argsWithSlot,
    arrayIntoIter, at, atProven, Box, chan, cloneAs, cloneErased,
    cloneOptional, cloneValue, Closure, codeView, cold, compare, copiedOut,
    copy, create, discard, discardAt, div, drop, dropErased, dropFailure,
    dropFields, dropParts, durationFloat,
    durationInt, durationNs, durationSum, elementAt, elemPtr,
    elemPtrProven, elems, Embed, embeds_aligned, endArm, Endian, enumFromInt,
    enumFromText, enumText, eql, ErasedClone, erasedCopy, ErasedDrop, ErasedOwn,
    ErasedPrint, ErasedRead, erasedSelf, erasedTake, ErasedUpgrade, ErasedWeak,
    ErasedWrite, ErrData, ErrorGlueOps, errorShown, ErrorValue, ErrSlot,
    eval_quota, exitStatus, expectShim, fail, failMain, failMainReported,
    failSlot, failValue, failWith, fill, finish, fixedText, floatClamp,
    floatMax, floatMin, FnRef, fold, frexpExponent, frexpFraction,
    Frozen, frozen, hash, Hasher, httpServe, indexBelow, InlineList, isError,
    isErrorDiscard, isNone, isolateInto, isVariant, isVariantDiscard, IterItem,
    keep, lag, lane, lenOf, lookup, makerPanic, mapTraceFound, mapTraceKey, mapTraceOp,
    MapTraceParam, MapTraceResult, mapTraceSee, Mask, mask, maskAll, maskAnd,
    maskAny, maskArray, maskBits, maskBitsNot, maskEq, maskFirst, maskNe,
    maskNot, maskOf, maskOr, maskSelect, maskTrueLanes, maskXor, namedTag,
    NameTable, net, no_error_data, no_slot, noneAt, notNan, notNone, okBelow,
    okNonneg, onOwnStack, Opt, Order, orderOf, outPlace, pack, packOut, panic,
    parEachCostInto, parEachInto, parMapCostInto, parMapInto,
    parPushCostInto, parPushInto, parWorkersCostInto, parWorkersInto,
    Payload, poison, pollValue,
    preempt_section, prefetch, print, Printer, printErased, readInt,
    readIntProven, ReadView, readView, Repr, recvArm, reduceInto, rem, reportFailure,
    rt, Select, selectInto, selectValue, selfArg, sendArm, Shared, shared,
    shiftAmount, showSlot, simdRead, simdReadProven, simdWrite, simdWriteProven,
    SiteTable, slice, sliceMut, SlotOf, slotOf, some, someOut, somePtr,
    someViewed, someViewedPtr, split, start, std_options, String, stringBytes,
    sum, superviseInto, swap, swapPlaces, swapProven, swapValue, take, takeOut,
    takesSlot, Test, testFalse, TextBuf, textGreater, textIs, textLess, through,
    tick_turns, tickCall, totalOrder, turn, typeName, unlikely, upgradeErased,
    upgradeTaken, vecAdd, vecAddSat, vecMul, vecNeg, vecShl, vecShlWrap, vecShr,
    vecSub, vecSubSat, viewed, viewedPtr, viewOf, waitTasksInto, warn, Weak,
    weakDropErased, weakErased, withLane, writeInt, writeIntProven, WritePtr,
};

/// The emitted spelling of runtime declaration `n`: `rig.NAME`. It is
/// inline so that its value is known at compile time, as `++` needs: a
/// spelling joined to the text around it (`rt(.at) ++ "("`) is then one
/// constant.
/// A name the runtime does not declare is a compile error in the
/// compiler where it is written, and the test below fails for any name on
/// the list the runtime lacks.
pub inline fn rt(comptime n: Name) *const [4 + @tagName(n).len:0]u8 {
    comptime if (!@hasDecl(runtime, @tagName(n))) @compileError("names.zig: the runtime declares no `" ++ @tagName(n) ++ "`");
    return "rig." ++ @tagName(n);
}

test "the runtime declares every name on the closed list" {
    inline for (comptime std.enums.values(Name)) |n| try std.testing.expect(@hasDecl(runtime, @tagName(n)));
}
