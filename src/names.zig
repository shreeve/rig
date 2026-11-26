//! The runtime's face: every declaration of the runtime
//! (`src/runtime.zig`) that emitted code names, as one closed list. Emit
//! writes a runtime name only through `rt`, so a name the list lacks is a
//! compile error in the compiler, and the check below makes the build
//! fail if the runtime stops declaring a name on the list.

const std = @import("std");
const runtime = @import("runtime.zig");

/// The runtime declarations emitted code may name, each spelled as the
/// runtime declares it.
pub const Name = enum {
    actor, actorCall, actorSpawn, actorSupervised, addIf, addProven, afterArm,
    ApiBox, ApiHolding, ApiShared, ApiView, ApiWeak, argsWithSlot,
    arrayIntoIter, at, atIf, atProven, Box, chan, cloneAs, cloneErased,
    cloneOptional, cloneValue, Closure, codeView, cold, compare, copiedOut,
    copy, create, discard, discardAt, div, drop, dropErased, dropFailure,
    dropFields, dropParts, durationFloat, durationFloatTry,
    durationInt, durationIntClamp, durationIntTry, durationNs, durationSum,
    durationSumClamp, durationSumTry, elementAt, elemPtr, elemPtrIf,
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
    parEachInto, parMapInto, parPushInto, parWorkersInto, Payload, poison,
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
pub inline fn rt(comptime n: Name) *const [4 + @tagName(n).len:0]u8 {
    return "rig." ++ @tagName(n);
}

comptime {
    for (std.enums.values(Name)) |n| {
        if (!@hasDecl(runtime, @tagName(n))) @compileError("names.zig: the runtime declares no `" ++ @tagName(n) ++ "`");
    }
}
