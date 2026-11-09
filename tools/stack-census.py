#!/usr/bin/env python3
"""stack-census.py EXE [--entries REGEX] [--top N] [--json FILE]: the most
stack each task of a built Rig program can take, read from the
executable's code alone, failing closed (docs/history/records/2026-11/
task-memory/small-stacks.md, the panel's step 4 and safety's R1).

A measurement, not yet a fact the runtime uses. For each function it
follows the stack pointer through the function's whole body, along its
branches, by a positive list of the instructions that may move it; any
other write to the stack pointer makes the function's frame unknown. A
function's bound is the most of its own frame it reaches, plus the red
zone (128 bytes on both targets), or the stack at a call plus the
callee's bound, whichever is more. A path through a cycle of calls, a
call out of the program's code (a libSystem stub), or an unknown frame
makes a bound unknown. An indirect call is bounded two ways: as unknown
(`direct`), and as the most of every function whose address the program
takes, in its code or its data (`resolved`).

A task's stack starts in `rig.sched.fiberStartNaked`, which calls
`fiberMain`, which calls the fiber's `run` through a pointer: one of
`sched.spawnIn`'s or `sched.spawnDetached`'s `Full.start`, one for each
type of task (`--entries`). Each is named by the program's function it
runs, from the debug information (`atos -i` on macOS,
`llvm-symbolizer --inlining` on Linux).

Needs llvm-objdump (`llvm-objdump-22` on pup) and, for the names,
atos or llvm-symbolizer.

usage: tools/stack-census.py EXE [--entries REGEX] [--top N] [--json FILE]
"""
import argparse, collections, json, os, re, shutil, subprocess, sys

RED_ZONE = 128
UNKNOWN = None
# The address of a thread-local, through the getter of its descriptor
# (macOS): an axiom, as the getter is libSystem's (`_tlv_get_addr`, a few
# words of frame once the thread's block exists, which each worker makes
# as it starts).
TLV = -1
TLV_BOUND = 256
# A call into the kernel's vDSO (Linux: the clock): bounded by this host's
# own vDSO image, read and analysed as the program is (`vdso_bound`), or
# unknown when it cannot be.
VDSO = -2
VDSO_BOUND = [None, "not measured"]
# The functions that leave the stack they run on, for another: what they
# push before the switch is all they take of it.
SWITCHES = re.compile(r"^rig\.(sched\.switchNaked|runtime\.switchStackNaked)$")
EXTRA_COLD = None
# `sched.onWorkerStack`: each call it makes runs on the worker's stack, or
# outside any task (its rules 4 and 5), so a task's bound counts its own
# frame alone.
ON_WORKER = re.compile(r"^rig\.sched\.onWorkerStack(__\w+)?$")
# Zig's `clone` (Linux): after the syscall, the branch taken when it
# gives 0 runs in the new thread, on the stack the call passed it, so the
# walk does not follow it (`clone_child`); the parent's path returns.
CLONE = re.compile(r"^os\.linux\.(x86_64|aarch64)\.clone$")
# Zig's stack probe (x86-64): it touches each page of the frame its caller
# is about to reserve, moving rsp down and back; the caller then reserves
# the frame itself (`mov eax, N; call; sub rsp, rax`).
PROBES = re.compile(r"(^|\.)(zig_probe_stack|__zig_probe_stack|__chkstk|___chkstk_darwin|__rust_probestack)$")
# The entries of the panic path (`rig.runtime.panicWith`, Zig's
# `FullPanic` handlers, `std.debug`'s panic and trace).
COLD = re.compile(r"(^rig\.runtime\.(panic|fullPanic|passPanic|outOfMemory|oom)|FullPanic|^debug\.(panic|defaultPanic|FullPanic|dumpCurrentStackTrace)|^builtin\.default_panic)")


def tool(*names):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    sys.exit("stack-census: none of %s on PATH" % ", ".join(names))


class Ins:
    __slots__ = ("addr", "op", "args")

    def __init__(self, addr, op, args):
        self.addr, self.op, self.args = addr, op, args


class Fn:
    __slots__ = ("name", "start", "ins", "own", "why", "calls", "icalls", "icalls_how", "islots", "tails", "itails", "foreign")

    def __init__(self, name, start):
        self.name, self.start, self.ins = name, start, []
        self.own = 0          # the most of its own frame, below its entry sp, at any point
        self.why = None       # why its frame is unknown
        self.calls = []       # (depth at the call, callee address): direct calls
        self.icalls = []      # (depth, address of the call): indirect calls
        self.icalls_how = []  # (depth, address, what loaded the register)
        self.islots = []      # (depth, slot offset, address): calls through a vtable's slot
        self.tails = []       # (depth, callee address): direct jumps out of the function
        self.itails = []      # (depth, address): indirect jumps that may leave it
        self.foreign = []     # callee names out of the program's code


def disassemble(exe, arch):
    objdump = tool("llvm-objdump", "llvm-objdump-22", "objdump")
    args = [objdump, "-d", "--no-show-raw-insn", "--print-imm-hex"]
    if arch == "x86_64":
        args.append("-M" "intel")
    out = subprocess.run(args + [exe], capture_output=True, text=True, check=True).stdout
    # Mach-O's `__rig_text` carries no instruction attributes, so `-d`
    # passes over it: disassembled by name, as every other section of
    # the program's code is by `-d`.
    if "Disassembly of section __TEXT,__rig_text:" not in out and section_range(exe, "__rig_text"):
        out += subprocess.run(args + ["-D", "--section=__rig_text", exe], capture_output=True, text=True, check=True).stdout
    fns, cur = [], None
    head = re.compile(r"^([0-9a-f]+) <(.+)>:$")
    line = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
    for l in out.splitlines():
        m = head.match(l)
        if m:
            cur = Fn(m.group(2), int(m.group(1), 16))
            fns.append(cur)
            continue
        m = line.match(l)
        if m and cur is not None:
            cur.ins.append(Ins(int(m.group(1), 16), m.group(2), m.group(3).strip()))
    return fns


def arch_of(exe):
    with open(exe, "rb") as f:
        h = f.read(20)
    if h[:4] == b"\xcf\xfa\xed\xfe":
        cpu = int.from_bytes(h[4:8], "little")
        return {0x0100000C: "aarch64", 0x01000007: "x86_64"}.get(cpu), "macho"
    if h[:4] == b"\x7fELF":
        m = int.from_bytes(h[18:20], "little")
        return {183: "aarch64", 62: "x86_64"}.get(m), "elf"
    sys.exit("stack-census: %s is neither Mach-O nor ELF" % exe)


TARGET = re.compile(r"0x([0-9a-f]+) <")


def target(args):
    m = TARGET.search(args)
    return int(m.group(1), 16) if m else None


def num(s):
    s = s.strip().lstrip("#")
    return int(s, 0)


# --- aarch64 -----------------------------------------------------------------

ARM_COND = re.compile(r"^(b\.\w+|cbn?z|tbn?z)$")
ARM_STOP = {"ret", "retaa", "retab", "brk", "udf", "hlt", "eret"}


def arm_effect(i, st):
    """How `i` moves sp, as (kind, value): ('add', n) moves the depth by n;
    ('set', n) sets it; ('bad', why); None leaves it."""
    op, a = i.op, i.args.split(";")[0].strip()
    regs = st["regs"]
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", a)] if a else []
    dest = parts[0] if parts else ""
    # Pre- and post-indexed stores and loads on sp.
    m = re.search(r"\[sp, #(-?0x[0-9a-f]+|-?\d+)\]!", a)
    if m:
        return ("add", -num(m.group(1)))
    m = re.search(r"\[sp\], #(-?0x[0-9a-f]+|-?\d+)", a)
    if m:
        return ("add", -num(m.group(1)))
    if op in ("sub", "add") and dest == "sp" and len(parts) >= 3:
        src, imm = parts[1], parts[2]
        if not imm.startswith("#"):
            return ("bad", "%s %s" % (op, a))
        n = num(imm)
        if len(parts) >= 4:
            if parts[3].replace(" ", "") != "lsl#12":
                return ("bad", "%s %s" % (op, a))
            n <<= 12
        if src == "sp":
            return ("add", n if op == "sub" else -n)
        if src in regs and regs[src] is not None:
            return ("set", regs[src] + (n if op == "sub" else -n))
        return ("bad", "%s %s" % (op, a))
    if op == "mov" and dest == "sp" and len(parts) == 2:
        src = parts[1]
        if src in regs and regs[src] is not None:
            return ("set", regs[src])
        return ("bad", "mov %s" % a)
    if op == "and" and dest == "sp" and len(parts) == 3:
        src, imm = parts[1], parts[2]
        if src in regs and regs[src] is not None and imm.startswith("#"):
            mask = num(imm) & 0xFFFFFFFFFFFFFFFF
            align = ((~mask) & 0xFFFFFFFFFFFFFFFF) + 1
            return ("set", regs[src] + align - 16)
        return ("bad", "and %s" % a)
    if dest == "sp" or dest == "wsp":
        return ("bad", "%s %s" % (op, a))
    return None


def arm_track(i, st, depth):
    """Registers that hold sp plus a known offset, as depths: `mov x29, sp`,
    `add x29, sp, #n`, `sub x9, sp, #n`."""
    op, a = i.op, i.args.split(";")[0].strip()
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", a)] if a else []
    if not parts:
        return
    dest = parts[0]
    regs = st["regs"]
    if not re.match(r"^[xw]\d+$|^fp$", dest):
        return
    dest = "x29" if dest == "fp" else dest
    if op == "mov" and len(parts) == 2 and parts[1] == "sp":
        regs[dest] = depth
    elif op in ("add", "sub") and len(parts) >= 3 and parts[1] == "sp" and parts[2].startswith("#"):
        n = num(parts[2])
        if len(parts) >= 4:
            if parts[3].replace(" ", "") != "lsl#12":
                regs.pop(dest, None)
                return
            n <<= 12
        regs[dest] = depth - n if op == "add" else depth + n
    elif op.startswith(("st", "cmp", "cmn", "tst", "b", "cb", "tb", "prfm")) and not op.startswith(("bic", "bfi", "bfxil")):
        return
    else:
        regs.pop(dest, None)
        if dest.startswith("w"):
            regs.pop("x" + dest[1:], None)


def arm_flow(i, fn_range):
    """('call', addr) | ('icall',) | ('jump', addr) | ('ijump',) | ('cond', addr) | ('stop',) | None."""
    op = i.op
    if op in ("bl",):
        return ("call", target(i.args))
    if op in ("blr", "blraa", "blrab", "blraaz", "blrabz"):
        return ("icall",)
    if op == "b":
        return ("jump", target(i.args))
    if op in ("br", "braa", "brab", "braaz", "brabz"):
        return ("ijump",)
    if ARM_COND.match(op):
        return ("cond", target(i.args))
    if op in ARM_STOP:
        return ("stop",)
    return None


# --- x86_64 ------------------------------------------------------------------

X86_STOP = {"ret", "ud2", "int3", "hlt", "ud1"}
X86_SP = re.compile(r"^(rsp|esp|sp|spl)$")


def x86_effect(i, st):
    op, a = i.op, i.args
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", a)] if a else []
    dest = parts[0] if parts else ""
    regs = st["regs"]
    if op in ("push", "pushq", "pushf", "pushfq"):
        return ("add", 8)
    if op in ("pop", "popq", "popf", "popfq"):
        if X86_SP.match(dest):
            return ("bad", "pop rsp")
        return ("add", -8)
    if op == "leave":
        if regs.get("rbp") is None:
            return ("bad", "leave with no frame")
        return ("set", regs["rbp"] - 8)
    if not X86_SP.match(dest):
        return None
    if op in ("sub", "add") and len(parts) == 2:
        src = parts[1]
        try:
            n = num(src)
        except ValueError:
            n = regs.get("imm:" + src.replace("e", "r", 1) if src.startswith("e") else "imm:" + src)
            if n is None:
                return ("bad", "%s %s" % (op, a))
        return ("add", n if op == "sub" else -n)
    if op == "lea" and len(parts) == 2:
        m = re.match(r"^\[(\w+)\s*([+-])\s*(0x[0-9a-f]+|\d+)\]$", parts[1]) or re.match(r"^\[(\w+)\]$", parts[1])
        if m:
            base = m.group(1)
            off = num(m.group(3)) * (1 if m.group(2) == "-" else -1) if m.lastindex and m.lastindex >= 3 else 0
            if base == "rsp":
                return ("add", off)
            if regs.get(base) is not None:
                return ("set", regs[base] + off)
        return ("bad", "lea %s" % a)
    if op == "mov" and len(parts) == 2 and regs.get(parts[1]) is not None:
        return ("set", regs[parts[1]])
    if op == "and" and len(parts) == 2:
        try:
            mask = num(parts[1]) & 0xFFFFFFFFFFFFFFFF
        except ValueError:
            return ("bad", "and %s" % a)
        align = ((~mask) & 0xFFFFFFFFFFFFFFFF) + 1
        return ("add", align - 8)
    return ("bad", "%s %s" % (op, a))


def x86_track(i, st, depth):
    op, a = i.op, i.args
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", a)] if a else []
    if not parts:
        return
    dest = parts[0]
    regs = st["regs"]
    if not re.match(r"^[re]?[a-z0-9]+$", dest) or X86_SP.match(dest):
        return
    full = ("r" + dest[1:]) if re.match(r"^e[a-z]{2}$", dest) else dest
    if op in ("cmp", "test", "push") or op.startswith("j") or op.startswith("call"):
        return
    if op == "mov" and len(parts) == 2 and parts[1] == "rsp":
        regs[full] = depth
        return
    regs.pop(full, None)
    regs.pop("imm:" + full, None)
    if op == "mov" and len(parts) == 2:
        try:
            regs["imm:" + full] = num(parts[1])
        except ValueError:
            pass


def x86_flow(i, fn_range):
    op = i.op
    if op.startswith("call"):
        t = target(i.args)
        return ("call", t) if t is not None and not i.args.startswith(("qword", "[")) and re.match(r"^0x", i.args) else ("icall",)
    if op == "jmp":
        t = target(i.args)
        m = re.match(r"^qword ptr \[8\*\w+ \+ 0x([0-9a-f]+)\]$", i.args)
        if m:
            return ("table", int(m.group(1), 16))
        return ("jump", t) if t is not None and re.match(r"^0x", i.args) else ("ijump",)
    if op.startswith("j"):
        return ("cond", target(i.args))
    if op in X86_STOP:
        return ("stop",)
    return None


# --- one function --------------------------------------------------------------

def kstep(i, kst, tlv_range, starts, depth=0):
    """aarch64, along one path: follow the registers whose value the code
    itself made, a function's address or a thread-local's getter (macOS:
    loaded from a descriptor in `__thread_vars`), through spills to the
    stack. For a call or jump through a register, its known target: a
    function's address, TLV, or None.

    A spill is kept by its place in the frame (its offset from sp less
    the depth), and only while nothing else may have written there: any
    store to the stack but a plain `str xN, [sp, #n]` forgets every
    spill, and so does any other store, or any call, once an address in
    the frame has left sp and the frame pointer (`add x0, sp, #n`), since
    a callee or a pointer may then write the frame."""
    addr, getter, slots = kst["addr"], kst["getter"], kst["slots"]
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", i.args)] if i.args else []
    dest = parts[0] if parts else ""
    plain = i.op == "str" and len(parts) == 2 and re.match(r"^x\d+$", dest) and re.match(r"^\[sp(?:, #(0x[0-9a-f]+|\d+))?\]$", parts[1])
    if i.op.startswith("st") and not plain:
        if re.search(r"\[(sp|x29|fp)\b", i.args) or kst.get("escaped"):
            slots.clear()
    if i.op in ("bl", "blr", "blraa", "blrab", "blraaz", "blrabz") and kst.get("escaped"):
        slots.clear()
    # An address in the frame copied out of sp or the frame pointer.
    outside = re.sub(r"\[[^\]]*\]!?", "", i.args)
    if re.search(r"\b(sp|x29|fp)\b", ",".join(outside.split(",")[1:])) and not (dest in ("sp", "x29", "fp") and re.search(r"\b(sp|x29|fp)\b", outside.split(",")[1] if "," in outside else "")):
        kst["escaped"] = True
    if i.op in ("blr", "br", "blraa", "blrab", "braa", "brab"):
        kst["how"] = kst.get("loads", {}).get(dest)
        t = TLV if dest in getter else addr.get(dest) if addr.get(dest) in starts else None
        if t == TLV:
            # The getter keeps every register but x0 (`_tlv_get_addr`).
            addr.pop("x0", None)
            getter.discard("x0")
            return t
        if i.op.startswith("bl"):
            for r in list(addr):
                if int(r[1:]) < 19:
                    addr.pop(r)
            for r in list(getter):
                if int(r[1:]) < 19:
                    getter.discard(r)
        return t
    if i.op == "bl":
        for r in list(addr):
            if int(r[1:]) < 19:
                addr.pop(r)
        for r in list(getter):
            if int(r[1:]) < 19:
                getter.discard(r)
        return None
    def clear(r):
        if re.match(r"^[xw]\d+$", r):
            addr.pop("x" + r[1:], None)
            getter.discard("x" + r[1:])
            kst.get("loads", {}).pop("x" + r[1:], None)
    if i.op == "adrp":
        m = re.match(r"^(x\d+), 0x([0-9a-f]+)", i.args)
        if m:
            clear(m.group(1))
            addr[m.group(1)] = int(m.group(2), 16)
        return None
    if i.op == "adr":
        t = target(i.args)
        clear(dest)
        if t is not None:
            addr[dest] = t
        return None
    if i.op == "add" and len(parts) == 3 and parts[1] in addr and parts[2].startswith("#"):
        v = addr[parts[1]] + num(parts[2])
        clear(dest)
        addr[dest] = v
        return None
    if i.op == "ldr" and len(parts) == 2:
        m = re.match(r"^\[(x\d+)\]$", parts[1])
        if m and tlv_range and m.group(1) in addr and tlv_range[0] <= addr[m.group(1)] < tlv_range[1]:
            clear(dest)
            getter.add(dest)
            return None
        loads = kst.setdefault("loads", {})
        m = re.match(r"^\[(x\d+)(?:, #(0x[0-9a-f]+|\d+))?\]$", parts[1])
        if m and m.group(1) != "sp" and re.match(r"^x\d+$", dest):
            b, off = m.group(1), num(m.group(2)) if m.group(2) else 0
            src_a, src_l = addr.get(b), loads.get(b)
            clear(dest)
            loads.pop(dest, None)
            if src_a is not None:
                loads[dest] = ("mem", src_a + off)
            elif src_l is not None and src_l[0] == "mem":
                loads[dest] = ("global", src_l[1], off)
            else:
                loads[dest] = ("slot", off)
            return None
        m = re.match(r"^\[sp(?:, #(0x[0-9a-f]+|\d+))?\]$", parts[1])
        if m:
            held = slots.get((num(m.group(1)) if m.group(1) else 0) - depth)
            clear(dest)
            if held == "tlv":
                getter.add(dest)
            elif held is not None:
                addr[dest] = held
            return None
    if i.op == "str" and len(parts) == 2:
        m = re.match(r"^\[sp(?:, #(0x[0-9a-f]+|\d+))?\]$", parts[1])
        if m:
            key = (num(m.group(1)) if m.group(1) else 0) - depth
            for k in [k for k in slots if abs(k - key) < 8]:
                del slots[k]
            slots[key] = "tlv" if dest in getter else addr.get(dest)
            return None
    if i.op == "mov" and len(parts) == 2 and re.match(r"^x\d+$", parts[1]):
        src = parts[1]
        g, v = src in getter, addr.get(src)
        clear(dest)
        if g:
            getter.add(dest)
        elif v is not None:
            addr[dest] = v
        return None
    if i.op.startswith("ldp"):
        for r in parts[:2]:
            clear(r)
        return None
    if not i.op.startswith(("st", "cmp", "cmn", "tst", "cb", "tb", "b", "prfm")):
        clear(dest)
    return None


X86_REG = re.compile(r"^(r[a-z0-9]+|e[a-z]{2}|e?[a-z]{2}|r\d+d?)$")
X86_KEEP = {"rbx", "rbp", "r12", "r13", "r14", "r15"}


def x86_full(r):
    if re.match(r"^e[a-z]{2}$", r):
        return "r" + r[1:]
    if re.match(r"^r\d+d$", r):
        return r[:-1]
    return r


def kstep_x86(i, kst, starts):
    """x86_64, along one path: the registers whose value the code made, a
    function's address (`mov eax, imm`, `lea reg, [rip + ...]`) or a load
    from a known global or through a vtable; for a call or jump through a
    register, its known target, or None (with `how` set)."""
    addr, loads = kst["addr"], kst.setdefault("loads", {})
    parts = [p.strip() for p in re.split(r",(?![^\[]*\])", i.args)] if i.args else []
    dest = x86_full(parts[0]) if parts else ""
    if i.op in ("call", "jmp") and parts and X86_REG.match(parts[0]):
        kst["how"] = loads.get(dest)
        t = addr.get(dest)
        if i.op == "call":
            for r in list(addr):
                if r not in X86_KEEP:
                    addr.pop(r)
            for r in list(loads):
                if r not in X86_KEEP:
                    loads.pop(r)
        return t if t in starts else None
    if i.op in ("call", "jmp") and parts and parts[0].startswith("qword ptr ["):
        m = re.match(r"^qword ptr \[(\w+)(?: \+ (0x[0-9a-f]+|\d+))?\]$", parts[0])
        kst["how"] = None
        if m:
            b, off = x86_full(m.group(1)), num(m.group(2)) if m.group(2) else 0
            if b in addr:
                kst["how"] = ("mem", addr[b] + off)
            elif b in loads and loads[b][0] == "mem":
                kst["how"] = ("global", loads[b][1], off)
            else:
                kst["how"] = ("slot", off)
        mm = re.search(r"# 0x([0-9a-f]+)", i.args)
        if mm and "rip" in parts[0]:
            kst["how"] = ("mem", int(mm.group(1), 16))
        return None
    if i.op == "call":
        for r in list(addr):
            if r not in X86_KEEP:
                addr.pop(r)
        for r in list(loads):
            if r not in X86_KEEP:
                loads.pop(r)
        return None
    if not parts or not X86_REG.match(parts[0]):
        return None
    addr.pop(dest, None)
    loads.pop(dest, None)
    if len(parts) != 2:
        return None
    src = parts[1]
    if i.op == "mov":
        try:
            v = num(src)
            addr[dest] = v
            return None
        except ValueError:
            pass
        if X86_REG.match(src):
            s2 = x86_full(src)
            if s2 in addr:
                addr[dest] = addr[s2]
            if s2 in loads:
                loads[dest] = loads[s2]
            return None
        m = re.match(r"^qword ptr \[(\w+)(?: \+ (0x[0-9a-f]+|\d+))?\]", src)
        if m:
            b, off = x86_full(m.group(1)), num(m.group(2)) if m.group(2) else 0
            mm = re.search(r"# 0x([0-9a-f]+)", i.args)
            if b == "rip" and mm:
                loads[dest] = ("mem", int(mm.group(1), 16))
            elif b in addr:
                loads[dest] = ("mem", addr[b] + off)
            elif b in loads and loads[b][0] == "mem":
                loads[dest] = ("global", loads[b][1], off)
            else:
                loads[dest] = ("slot", off)
        return None
    if i.op == "lea":
        mm = re.search(r"# 0x([0-9a-f]+)", i.args)
        if "rip" in src and mm:
            addr[dest] = int(mm.group(1), 16)
    return None


def clone_child(ins, k):
    """Whether the branch at `ins[k]` is `clone`'s to its child: the test
    of the syscall's result just after the syscall (`syscall; test rax,
    rax; je` on x86-64, `svc #0; cbz x0` on arm64), whose fall-through is
    the parent's `ret`."""
    i = ins[k]
    nxt = ins[k + 1] if k + 1 < len(ins) else None
    if nxt is None or nxt.op not in ("ret", "retq"):
        return False
    if i.op in ("je", "jz") and k >= 2:
        return ins[k - 1].op == "test" and ins[k - 1].args.replace(" ", "") == "rax,rax" and ins[k - 2].op == "syscall"
    if i.op == "cbz" and k >= 1:
        return i.args.startswith("x0,") and ins[k - 1].op == "svc" and ins[k - 1].args.strip("# ") in ("0", "0x0")
    return False


def analyse(fn, end, arch, code, starts, tlv_range=None, words=None):
    if PROBES.search(fn.name):
        fn.own = 16
        return
    """Fill `fn`'s own frame, calls and jumps by a walk of its branches.
    Compiled code keeps the stack pointer the same at each point however
    the point is reached, so a point reached at two depths makes the frame
    unknown: a write to sp this does not read, or a frame that changes."""
    if not fn.ins:
        return
    effect = arm_effect if arch == "aarch64" else x86_effect
    track = arm_track if arch == "aarch64" else x86_track
    flow = arm_flow if arch == "aarch64" else x86_flow
    index = {ins.addr: k for k, ins in enumerate(fn.ins)}
    seen = {}
    ijumps = []

    def in_code(t):
        return any(lo <= t < hi for lo, hi in code)

    def walk(k, depth, regs):
        work = [(k, depth, regs, {"addr": {}, "getter": set(), "slots": {}})]
        while work:
            k, depth, regs, kst = work.pop()
            while k < len(fn.ins):
                if k in seen:
                    if seen[k] != depth:
                        fn.why = fn.why or "sp is %d and %d at %#x" % (seen[k], depth, fn.ins[k].addr)
                        return False
                    break
                seen[k] = depth
                ins = fn.ins[k]
                st = {"regs": regs}
                e = effect(ins, st)
                if e is not None:
                    if e[0] == "bad" and SWITCHES.search(fn.name):
                        # The stack is left here: what follows runs on another.
                        break
                    if e[0] == "bad":
                        fn.why = fn.why or "sp written by `%s %s` at %#x" % (ins.op, ins.args, ins.addr)
                        return False
                    depth = depth + e[1] if e[0] == "add" else e[1]
                track(ins, st, depth)
                kt = kstep(ins, kst, tlv_range, starts, depth) if arch == "aarch64" else kstep_x86(ins, kst, starts)
                fn.own = max(fn.own, depth)
                f = flow(ins, (fn.start, end))
                if f is None:
                    k += 1
                    continue
                kind = f[0]
                if kind == "stop":
                    break
                if kind == "call":
                    t = f[1]
                    if t is None:
                        fn.why = fn.why or "a call with no target at %#x" % ins.addr
                        return False
                    if in_code(t):
                        fn.calls.append((depth, t))
                    else:
                        fn.foreign.append(t)
                    k += 1
                    continue
                if kind == "icall":
                    if kt is not None:
                        # Through a register the code set to a function, or
                        # to a thread-local's getter (macOS; an axiom,
                        # TLV_BOUND).
                        fn.calls.append((depth, kt))
                    else:
                        fn.icalls.append((depth, ins.addr))
                        fn.icalls_how.append((depth, ins.addr, kst.get("how")))
                    k += 1
                    continue
                if kind == "cond" and CLONE.search(fn.name) and clone_child(fn.ins, k):
                    k += 1
                    continue
                if kind in ("jump", "cond"):
                    t = f[1]
                    if t is not None and t in index:
                        work.append((index[t], depth, dict(regs), {"addr": dict(kst["addr"]), "getter": set(kst["getter"]), "slots": dict(kst["slots"]), "loads": dict(kst.get("loads", {})), "escaped": kst.get("escaped", False)}))
                    elif t is not None:
                        if in_code(t):
                            fn.tails.append((depth, t))
                        else:
                            fn.foreign.append(t)
                    else:
                        fn.why = fn.why or "a jump with no target at %#x" % ins.addr
                        return False
                    if kind == "jump":
                        break
                    k += 1
                    continue
                if kind == "table":
                    # A jump table of absolute addresses (x86-64): each
                    # entry in the function is a branch at this depth.
                    t, n = f[1], 0
                    while words is not None and words.get(t) in index:
                        work.append((index[words[t]], depth, dict(regs), {"addr": dict(kst["addr"]), "getter": set(kst["getter"]), "slots": dict(kst["slots"]), "loads": dict(kst.get("loads", {})), "escaped": kst.get("escaped", False)}))
                        t += 8
                        n += 1
                    if n == 0:
                        fn.itails.append((depth, ins.addr))
                    break
                if kind == "ijump" and kt is not None:
                    fn.tails.append((depth, kt))
                    break
                if kind == "ijump" and depth == 0 and fn.own > 0:
                    # After the epilogue: a tail call through a pointer.
                    fn.itails.append((depth, ins.addr))
                    break
                if kind == "ijump":
                    ijumps.append(depth)
                    fn.itails.append((depth, ins.addr))
                    break
                k += 1
        return True

    if not walk(0, 0, {}):
        return
    # An indirect jump goes to a jump table's targets, which no direct path
    # reaches, at its own depth; or leaves the function, as an indirect
    # call does (`itails`).
    done = 0
    while done < len(ijumps):
        depths = set(ijumps[done:])
        done = len(ijumps)
        if len(set(ijumps)) > 1:
            fn.why = fn.why or "indirect jumps at depths %s" % sorted(set(ijumps))
            return
        d = depths.pop()
        for k in range(len(fn.ins)):
            if k not in seen and not walk(k, d, {}):
                return


# --- addresses the program takes --------------------------------------------------

def section_range(exe, name):
    objdump = tool("llvm-objdump", "llvm-objdump-22", "objdump")
    heads = subprocess.run([objdump, "-h", exe], capture_output=True, text=True, check=True).stdout
    for l in heads.splitlines():
        m = re.match(r"^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)", l)
        if m and m.group(1) == name:
            lo = int(m.group(3), 16)
            return (lo, lo + int(m.group(2), 16))
    return None


def stubs_of(exe):
    """A Mach-O executable's stubs to libSystem: address to name."""
    objdump = tool("llvm-objdump", "llvm-objdump-22", "objdump")
    out = subprocess.run([objdump, "--macho", "--indirect-symbols", exe], capture_output=True, text=True).stdout
    names = {}
    for l in out.splitlines():
        m = re.match(r"^0x([0-9a-f]+)\s+\d+\s+(\S+)", l)
        if m:
            names[int(m.group(1), 16)] = m.group(2).lstrip("_")
    return names


def code_sections(exe):
    """The program's code: `__text` and `rig_text` (Mach-O `__rig_text`),
    as (start, end). Stubs to libSystem are not in it."""
    objdump = tool("llvm-objdump", "llvm-objdump-22", "objdump")
    heads = subprocess.run([objdump, "-h", exe], capture_output=True, text=True, check=True).stdout
    out = []
    for l in heads.splitlines():
        m = re.match(r"^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)", l)
        if m and m.group(1) in ("__text", ".text", "__rig_text", "rig_text"):
            lo = int(m.group(3), 16)
            out.append((lo, lo + int(m.group(2), 16)))
    return out


def taken_in_code(fns, arch, starts):
    taken = set()
    for fn in fns:
        page = {}
        for ins in fn.ins:
            if arch == "aarch64":
                if ins.op == "adrp":
                    m = re.match(r"^(x\d+), 0x([0-9a-f]+)", ins.args)
                    if m:
                        page[m.group(1)] = int(m.group(2), 16)
                    continue
                if ins.op == "add":
                    m = re.match(r"^(x\d+), (x\d+), #(0x[0-9a-f]+|\d+)$", ins.args)
                    if m and m.group(2) in page:
                        a = page[m.group(2)] + num(m.group(3))
                        if a in starts:
                            taken.add(a)
                if ins.op == "adr":
                    t = target(ins.args)
                    if t in starts:
                        taken.add(t)
            else:
                if ins.op in ("lea", "mov"):
                    m = re.search(r"# 0x([0-9a-f]+)", ins.args)
                    if m and int(m.group(1), 16) in starts:
                        taken.add(int(m.group(1), 16))
                    for t in re.findall(r"0x([0-9a-f]+)", ins.args):
                        if int(t, 16) in starts and fn.start != int(t, 16):
                            taken.add(int(t, 16))
    return taken


def data_words(exe, fmt, starts):
    """The words of the data sections, by address, decoded: in a Mach-O
    executable a pointer is a chained fixup, whose low 36 bits are its
    target's offset from the image's base. Returns (words, pointers to
    functions by address)."""
    objdump = tool("llvm-objdump", "llvm-objdump-22", "objdump")
    heads = subprocess.run([objdump, "-h", exe], capture_output=True, text=True, check=True).stdout
    names = []
    for l in heads.splitlines():
        m = re.match(r"^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s*(\S+)?", l)
        if not m or int(m.group(2), 16) == 0:
            continue
        n = m.group(1)
        if n in ("__text", ".text", "__stubs", "__stub_helper", "rig_text", "__rig_text", "__thread_bss", ".bss", "__bss", "__common", ".tbss") or n.startswith((".debug", "__debug", ".eh_frame", "__eh_frame", "__unwind", ".symtab", ".strtab", ".shstrtab", "__cstring", ".comment", "__apple", "__DWARF")):
            continue
        names.append(n)
    base = min(starts) & ~0xFFFFFFF if fmt == "macho" else 0
    # A word already inside the image is an address as it stands (a
    # pointer the linker wrote out whole); any other is a chained fixup.
    top = max((int(m.group(3), 16) + int(m.group(2), 16) for m in (re.match(r"^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)", l) for l in heads.splitlines()) if m), default=0)
    words, fptr = {}, {}
    # A name may stand for several sections (Mach-O's `__TEXT,__const` and
    # `__DATA_CONST,__const`), each dumped at its own addresses: the bytes
    # are kept in runs of neighbouring lines, never joined across a gap.
    for n in dict.fromkeys(names):
        out = subprocess.run([objdump, "-s", "-j", n, exe], capture_output=True, text=True).stdout
        runs = []
        for l in out.splitlines():
            m = re.match(r"^ ([0-9a-f]+) ((?:[0-9a-f]{2,8} ?){1,4})", l)
            if not m:
                continue
            a, b = int(m.group(1), 16), bytes.fromhex(m.group(2).replace(" ", ""))
            if runs and runs[-1][0] + len(runs[-1][1]) == a:
                runs[-1][1].extend(b)
            else:
                runs.append((a, bytearray(b)))
        for lo, data in runs:
            # Every word at a 4-byte boundary: a pointer packed at one is
            # still a function's address taken.
            for k in range((-lo) % 4, len(data) - 7, 4):
                w = int.from_bytes(data[k:k + 8], "little")
                v = w
                if fmt == "macho" and not base <= w < top and not (w >> 63):
                    v = base + (w & 0xFFFFFFFFF)
                words[lo + k] = v
                if v in starts:
                    fptr[lo + k] = v
    return words, fptr


def vdso_bound(arch):
    """This host's vDSO `clock_gettime`, bounded as a program's function is:
    the image read from this process's memory (/proc/self/maps, `[vdso]`),
    disassembled and walked. (bytes, None), or (None, why)."""
    try:
        lo = hi = None
        for l in open("/proc/self/maps"):
            if l.rstrip().endswith("[vdso]"):
                a, b = l.split()[0].split("-")
                lo, hi = int(a, 16), int(b, 16)
        if lo is None:
            return (None, "no [vdso] in /proc/self/maps")
        with open("/proc/self/mem", "rb") as m:
            m.seek(lo)
            image = m.read(hi - lo)
    except OSError as e:
        return (None, "cannot read it: %s" % e)
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".so", delete=False) as f:
        f.write(image)
        path = f.name
    try:
        fns = disassemble(path, arch)
        fns.sort(key=lambda f: f.start)
        # The image names only its exported functions: each other call's
        # target starts a function of its own, split from the one it is in.
        targets = set()
        for fn in fns:
            last = fn.ins[-1].addr if fn.ins else fn.start
            for i in fn.ins:
                if i.op in ("call", "bl", "jmp", "b"):
                    t = target(i.args)
                    if t is not None and (i.op in ("call", "bl") or not fn.start <= t <= last):
                        targets.add(t)
        for t in sorted(targets):
            for fn in fns:
                if fn.start < t and fn.ins and fn.ins[-1].addr >= t:
                    k = next((j for j, i in enumerate(fn.ins) if i.addr == t), None)
                    if k is not None:
                        g = Fn("vdso+%#x" % t, t)
                        g.ins, fn.ins = fn.ins[k:], fn.ins[:k]
                        fns.append(g)
                    break
        fns.sort(key=lambda f: f.start)
        starts = {f.start for f in fns}
        code = code_sections(path) or [(fns[0].start, fns[-1].start + 4096)] if fns else []
        for k, fn in enumerate(fns):
            end = fns[k + 1].start if k + 1 < len(fns) else fn.start + 4 * len(fn.ins) + 16
            analyse(fn, end, arch, code, starts)
        b = bounds(fns, arch, None)
        best, why = 0, None
        found = [fn for fn in fns if fn.name.endswith("clock_gettime")]
        if not found:
            return (None, "no clock_gettime in the image")
        for fn in found:
            c, w, fo = b(fn.start)
            if c is UNKNOWN or fo:
                return (None, w or "it calls out: %s" % ", ".join(sorted(fo)))
            best = max(best, c)
        return (best, None)
    finally:
        os.unlink(path)


def zig_lib():
    """Zig's lib directory, from `zig env`."""
    z = shutil.which("zig")
    if not z:
        return None
    out = subprocess.run([z, "env"], capture_output=True, text=True).stdout
    m = re.search(r'\.lib_dir = "([^"]+)"', out)
    if not m:
        return None
    d = m.group(1)
    return d if os.path.isabs(d) else os.path.join(os.path.expanduser("~"), d)


def vtable_fields(lib, namespace, cache={}):
    """The fields of `namespace`'s `VTable`, in order, from Zig's std source
    (`Io.Writer` is std/Io/Writer.zig, `Io` std/Io.zig), or None."""
    if namespace in cache:
        return cache[namespace]
    cache[namespace] = None
    if lib is None:
        return None
    path = os.path.join(lib, "std", *namespace.split(".")) + ".zig"
    if not os.path.exists(path):
        return None
    text = open(path).read()
    m = re.search(r"\npub const VTable = struct \{\n(.*?)\n\};", text, re.S)
    if not m:
        return None
    fields = re.findall(r"^    (@\"[^\"]+\"|\w+): \*const fn", m.group(1), re.M)
    cache[namespace] = [f.strip('@"') for f in fields] or None
    return cache[namespace]


FNREF_CALL = re.compile(r"^rig\.runtime\.(FnRef\(.*\))\.call$")
FNREF_THUNK = re.compile(r"^rig\.runtime\.(FnRef\(.*\))\.(of|ofFn|ofClosure)(__\w+)?\.thunk\.call$")


def fnref_fact(src):
    """Whether Rig's sources at `src` hold the fact a call through a
    `FnRef` is resolved by: a `FnRef`'s function is set only by its own
    `of`, `ofFn` and `ofClosure`, each to its thunk. Checked, failing
    closed: in src/runtime.zig's `FnRef`, every mention of `call_fn` is
    the field, a thunk stored by one of the three, or the call; and no
    other file of src/ or std/ mentions it, but a type of its own that
    declares a field of that name (a test's stand-in). (None, why) when
    it does not hold or cannot be read."""
    try:
        rt = open(os.path.join(src, "src", "runtime.zig")).read()
    except OSError as e:
        return "cannot read Rig's runtime: %s" % e
    m = re.search(r"\npub fn FnRef\(.*?\n\}\n", rt, re.S)
    if not m:
        return "no FnRef in src/runtime.zig"
    body = m.group(0)
    ok = (r"^\s*call_fn: \*const fn \(\*anyopaque, Args\) R,$", r"^\s*return \.\{ \.ctx = .*, \.call_fn = thunk\.call \};$", r"^\s*return self\.call_fn\(self\.ctx, args\);$")
    stores = 0
    for l in body.splitlines():
        if "call_fn" in l:
            if not any(re.match(r, l) for r in ok):
                return "FnRef's call_fn used so: %s" % l.strip()
            stores += ".call_fn = " in l
    if stores != 3 or len(re.findall(r"\n        pub fn (of|ofFn|ofClosure)\(", body)) != 3:
        return "FnRef is not made by of, ofFn and ofClosure alone"
    rest = rt[:m.start()] + rt[m.end():]
    files = [("src/runtime.zig (outside FnRef)", rest)]
    for d in ("src", "std"):
        for root, _, names in os.walk(os.path.join(src, d)):
            for n in names:
                if n.endswith(".zig") and not (d == "src" and n in ("runtime.zig", "parser.zig")):
                    files.append((os.path.join(root, n), open(os.path.join(root, n)).read()))
    for name, text in files:
        if "call_fn" in text and ("FnRef" in "".join(l for l in text.splitlines() if "call_fn" in l) or not re.search(r"\bcall_fn: \*const fn", text)):
            return "%s sets a FnRef's call_fn" % name
    return None


def inline_frames(exe, fmt, addrs):
    """For each address, its inline frames' function names, innermost first."""
    if not addrs:
        return {}
    out = {}
    hexes = ["%#x" % a for a in addrs]
    for k in range(0, len(hexes), 500):
        part = hexes[k:k + 500]
        if fmt == "macho":
            p = subprocess.run(["atos", "-o", exe, "-i"] + part, capture_output=True, text=True)
            groups = p.stdout.split("\n\n")
            for a, g in zip(part, groups):
                out[int(a, 16)] = [l.split(" (in ")[0].strip() for l in g.strip().splitlines() if " (in " in l]
        else:
            sym = tool("llvm-symbolizer", "llvm-symbolizer-22")
            p = subprocess.run([sym, "--inlining", "-e", exe] + part, capture_output=True, text=True)
            groups = p.stdout.strip("\n").split("\n\n")
            for a, g in zip(part, groups):
                lines = g.strip().splitlines()
                out[int(a, 16)] = [lines[i].strip() for i in range(0, len(lines), 2)]
    return out


def type_vtables(runs, names, lib, namespaces):
    """The vtables of each interface among the data's runs of function
    pointers: a window of a run as long as the interface's `VTable`, most
    of whose functions are named for its fields (`heap.SmpAllocator.alloc`
    at `alloc`, `Io.Writer.failingDrain` at `drain`). By namespace, the
    functions at each slot."""
    typed = {}
    for ns in namespaces:
        fields = vtable_fields(lib, ns)
        if not fields:
            continue
        n = len(fields)
        slots = [set() for _ in range(n)]
        for r in runs:
            for st in range(0, len(r) - n + 1):
                w = r[st:st + n]
                score = sum(1 for f, fld in zip(w, fields) if fld.lower() in names.get(f, "").rsplit(".", 1)[-1].lower())
                if score * 2 >= n and score >= min(2, n):
                    for j, f in enumerate(w):
                        slots[j].add(f)
        if any(slots):
            typed[ns] = [sorted(x) for x in slots]
    return typed


def vtable_runs(fptr):
    """Runs of function pointers at neighbouring words: vtables, or several
    side by side."""
    runs, cur = [], []
    for a in sorted(fptr):
        if cur and a == cur[-1][0] + 8:
            cur.append((a, fptr[a]))
        else:
            if len(cur) >= 2:
                runs.append([f for _, f in cur])
            cur = [(a, fptr[a])]
    if len(cur) >= 2:
        runs.append([f for _, f in cur])
    return runs


# --- bounds --------------------------------------------------------------------------

def bounds(fns, arch, resolved, by_slot=None):
    """Each function's bound by address: (bytes or None, why, the foreign
    functions on its paths). A call out of the program's code counts as no
    stack: the step after this census runs each such call on the worker's
    stack (safety's R3), and the census lists them so."""
    by = {fn.start: fn for fn in fns}
    # The panic path: it moves to the worker's stack (safety's R5), and a
    # task's bound counts only a fixed stub for it.
    cold = {fn.start for fn in fns if COLD.search(fn.name) or EXTRA_COLD and EXTRA_COLD.search(fn.name)}
    ret_addr = 8 if arch == "x86_64" else 0
    memo, onpath = {}, set()
    sys.setrecursionlimit(100000)

    def b(addr):
        if addr == TLV:
            return (TLV_BOUND, None, frozenset())
        if addr == VDSO:
            vb, vw = VDSO_BOUND
            return (vb, None if vb is not None else "the vDSO: " + vw, frozenset())
        if addr in cold:
            return (0, None, frozenset(["(panic) " + by[addr].name]))
        if addr in memo:
            return memo[addr]
        fn = by.get(addr)
        if fn is None:
            return (UNKNOWN, "a call into the middle of a function at %#x" % addr, frozenset())
        if addr in onpath:
            return (UNKNOWN, "a cycle of calls through %s" % fn.name, frozenset())
        if fn.why:
            memo[addr] = (UNKNOWN, "%s: %s" % (fn.name, fn.why), frozenset())
            return memo[addr]
        if ON_WORKER.search(fn.name):
            memo[addr] = (fn.own + RED_ZONE, None, frozenset())
            return memo[addr]
        onpath.add(addr)
        best, why, foreign = fn.own + RED_ZONE, None, set(fn.foreign)
        edges = [(d + ret_addr, t) for d, t in fn.calls] + list(fn.tails)
        ind = [(d + ret_addr, a) for d, a in fn.icalls] + list(fn.itails)
        if by_slot is not None:
            edges += [(d + ret_addr, c) for d, off, at in fn.islots for c in by_slot(at, off)]
        else:
            ind += [(d + ret_addr, a) for d, _, a in fn.islots]
        for d, t in edges:
            c, w, fo = b(t)
            foreign |= fo
            if c is UNKNOWN:
                best, why = UNKNOWN, w
                break
            best = max(best, d + c)
        if best is not UNKNOWN and ind:
            if resolved is None:
                best, why = UNKNOWN, "%s calls through a pointer at %#x" % (fn.name, ind[0][1])
            else:
                c, w, fo = resolved()
                foreign |= fo
                if c is UNKNOWN or w is not None and c is UNKNOWN:
                    best, why = UNKNOWN, w
                else:
                    best = max(best, max(d for d, _ in ind) + c)
        onpath.discard(addr)
        r = (best, why, frozenset(foreign))
        # A result reached under a cycle elsewhere on the path is not kept,
        # since it may depend on that path.
        if not (best is UNKNOWN and why and why.startswith("a cycle")):
            memo[addr] = r
        return r

    return b


def names_of(exe, fmt, entry_fns, program_files, by=None):
    """The program's function each entry runs: the outermost frame from the
    program's own files in the inline frames of its code, and of the
    `rig.runtime.inCode` it calls (a preempted build's: the program's code
    is inlined there, in the preempted section)."""
    out = {}
    for fn in entry_fns:
        code = [fn] + [by[t] for _, t in fn.calls + fn.tails if by and t in by and INCODE.search(by[t].name)]
        # A task that runs a closure (`par.map`'s): the thunks of the
        # `FnRef` it calls, where the closure's code is.
        code += [by[t] for f in code[1:] for _, t in f.calls if t in by and FNREF_THUNK.search(by[t].name)]
        addrs = ["%#x" % i.addr for f in code for i in f.ins[:400]]
        if fmt == "macho":
            p = subprocess.run(["atos", "-o", exe, "-i"] + addrs, capture_output=True, text=True)
            frames = p.stdout.splitlines()
            pat = re.compile(r"^(\S+) \(in [^)]*\) \(([^:]+):(\d+)\)")
        else:
            sym = tool("llvm-symbolizer", "llvm-symbolizer-22")
            p = subprocess.run([sym, "--inlining", "--no-demangle", "-e", exe] + addrs, capture_output=True, text=True)
            lines = p.stdout.splitlines()
            frames = []
            for k in range(0, len(lines) - 1):
                if lines[k] and lines[k + 1].startswith(("/", ".")) or re.match(r"^\S.*:\d+:\d+$", lines[k + 1] or ""):
                    frames.append("%s (in x) (%s)" % (lines[k], os.path.basename(lines[k + 1].rsplit(":", 2)[0]) + ":" + lines[k + 1].rsplit(":", 2)[1]))
            pat = re.compile(r"^(\S+) \(in [^)]*\) \(([^:]+):(\d+)\)")
        names = collections.Counter()
        for fr in frames:
            m = pat.match(fr.strip())
            if m and m.group(2) in program_files:
                names[m.group(1)] += 1
        out[fn.start] = ", ".join(n for n, _ in names.most_common(3))
    return out


INCODE = re.compile(r"^rig\.runtime\.inCode(__\w+)?$")


# Namespaces of Zig's std and of Rig's runtime: a function outside them is
# the program's.
NOT_PROGRAM = re.compile(r"^(rig\.|__rig_std|std\.|heap\.|mem\.|Io\.|debug\.|array_list\.|fmt\.|math\.|hash\.|sort\.|crypto\.|posix\.|os\.|Thread\.|atomic\.|unicode\.|process\.|builtin\.|c\.|start\.|compiler_rt\.|hash_map\.|ascii\.|time\.|Target\.|dwarf\.|leb128\.|simd\.|static_string_map\.|enums\.|meta\.|Progress\.|log\.|json\.|zig\.|elf\.|macho\.|coff\.|pdb\.|tar\.|compress\.|http\.|net\.|fs\.|testing\.|Random\.|Uri\.|multi_array_list\.|priority_queue\.|bit_set\.|base64\.|unicode)")


def called_names(fn, by, depth=3):
    """The program's functions an entry calls directly, a few calls down."""
    seen, out, frontier = set(), [], [fn]
    for _ in range(depth):
        nxt = []
        for f in frontier:
            for _, t in f.calls + f.tails:
                g = by.get(t)
                if g is None or t in seen:
                    continue
                seen.add(t)
                if "." in g.name and not NOT_PROGRAM.search(g.name):
                    out.append(g.name)
                else:
                    nxt.append(g)
        if out:
            return out
        frontier = nxt
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("exe")
    ap.add_argument("--entries", default=r"rig\.sched\.spawn(In|Detached)__\w+\.Full\.start$")
    ap.add_argument("--top", type=int, default=15, help="the deepest functions to list")
    ap.add_argument("--json")
    ap.add_argument("--cold", help="also count these functions as run off the task's stack, as a step that moves them would (a what-if)")
    ap.add_argument("--rig-src", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))), help="the Rig checkout whose runtime built EXE, for the fact a FnRef call is resolved by (default: this tool's)")
    ap.add_argument("--program-files", default="", help="emitted files of the program, comma-separated (default: the build's __rig_*.zig and module files)")
    a = ap.parse_args()
    global EXTRA_COLD
    EXTRA_COLD = re.compile(a.cold) if a.cold else None
    arch, fmt = arch_of(a.exe)
    fns = disassemble(a.exe, arch)
    for fn in fns:
        if fmt == "macho" and fn.name.startswith("_"):
            fn.name = fn.name[1:]
    fns.sort(key=lambda f: f.start)
    code = code_sections(a.exe)
    tlv = section_range(a.exe, "__thread_vars")
    stub_names = stubs_of(a.exe) if fmt == "macho" else {}
    fns = [fn for fn in fns if any(lo <= fn.start < hi for lo, hi in code)]
    starts = {fn.start for fn in fns}
    words, fptr = data_words(a.exe, fmt, starts)
    for k, fn in enumerate(fns):
        end = fns[k + 1].start if k + 1 < len(fns) else fn.start + 4 * len(fn.ins) + 16
        analyse(fn, end, arch, code, starts, tlv, words)
        fn.foreign = [stub_names.get(t, "%#x" % t) for t in fn.foreign]
    taken = taken_in_code(fns, arch, starts) | set(fptr.values())
    runs = vtable_runs(fptr)
    slot_sets = {}
    # The interface of each call through a slot: the innermost frame of the
    # call's inlined code that names a std namespace with a `VTable`.
    lib = zig_lib()
    slot_calls = [at for fn in fns for _, at, how in fn.icalls_how]
    frames = inline_frames(a.exe, fmt, slot_calls)
    iface = {}
    for at, fr in frames.items():
        for name in fr:
            parts = name.split(".")
            for cut in range(len(parts) - 1, 0, -1):
                ns = ".".join(parts[:cut])
                if vtable_fields(lib, ns):
                    iface[at] = ns
                    break
            if at in iface:
                break
        if fr and fr[0].startswith("os.linux.clock_gettime"):
            iface[at] = "vdso"
    names_by = {fn.start: fn.name for fn in fns}
    typed = type_vtables(runs, names_by, lib, set(v for v in iface.values() if v != "vdso"))

    def by_call(at, off):
        ns = iface.get(at)
        j = off // 8
        if ns in typed and j < len(typed[ns]) and typed[ns][j]:
            return typed[ns][j]
        return by_slot(off)

    def by_slot(off):
        j = off // 8
        if j not in slot_sets:
            slot_sets[j] = sorted({f for r in runs if len(r) > j for f in r[j:]})
        return slot_sets[j]

    # Calls through a vtable a global holds: the global's value in the file
    # names the vtable, and the slot the function. Calls through a slot of
    # an unknown vtable: every function at that slot or after in any run.
    if fmt == "elf" and any(v == "vdso" for v in iface.values()):
        VDSO_BOUND[:] = list(vdso_bound(arch))
        print("the vDSO's clock_gettime on this host: %s" % ("%d B" % VDSO_BOUND[0] if VDSO_BOUND[0] is not None else "unknown: " + VDSO_BOUND[1]))
    # A call through a `FnRef`: every thunk of its type, as Rig's runtime
    # makes them (`fnref_fact`), when the fact holds and the type has any.
    thunks = collections.defaultdict(list)
    for fn in fns:
        m = FNREF_THUNK.search(fn.name)
        if m:
            thunks[m.group(1)].append(fn.start)
    fnref_why = fnref_fact(a.rig_src) if any(fr and FNREF_CALL.search(fr[0]) for fr in frames.values()) else None
    if fnref_why:
        print("calls through a FnRef: unresolved, %s" % fnref_why)
    for fn in fns:
        exact, slots, rest = [], [], []
        for d, at, how in fn.icalls_how:
            if iface.get(at) == "vdso":
                exact.append((d, VDSO))
                continue
            fr = frames.get(at) or []
            m = FNREF_CALL.search(fr[0]) if fr else None
            if m and not fnref_why and thunks.get(m.group(1)):
                exact += [(d, t) for t in thunks[m.group(1)]]
                continue
            if how and how[0] == "mem":
                # A function pointer a global holds: its value in the file.
                t = words.get(how[1])
                if t in starts:
                    exact.append((d, t))
                    continue
            if how and how[0] == "global":
                vt = words.get(how[1])
                t = words.get(vt + how[2]) if vt is not None else None
                if t in starts:
                    exact.append((d, t))
                    continue
            if how and how[0] in ("global", "slot"):
                slots.append((d, how[-1], at))
                continue
            rest.append((d, at))
        fn.calls += exact
        fn.icalls = rest
        fn.islots = slots
    direct = bounds(fns, arch, None)
    # An indirect call costs the most any address-taken function may take,
    # which may itself call through a pointer: the least bound that holds,
    # found by iterating from none. It grows without end only through a
    # cycle of calls through pointers, which makes it unknown.
    reach, why_t, fo_t = 0, None, frozenset()
    for _ in range(64):
        cur = (reach, None, fo_t)
        b = bounds(fns, arch, lambda cur=cur: cur, by_call)
        nxt, why_t, fo = 0, None, set(fo_t)
        for t in sorted(taken):
            c, w, f = b(t)
            fo |= f
            if c is UNKNOWN:
                nxt, why_t = UNKNOWN, "through a pointer, %s" % w
                break
            nxt = max(nxt, c)
        fo_t = frozenset(fo)
        if nxt is UNKNOWN or nxt == reach:
            reach = nxt
            break
        reach = nxt
    else:
        reach, why_t = UNKNOWN, "through a pointer, a cycle of calls through pointers"
    with_taken = bounds(fns, arch, lambda: (reach, why_t, fo_t), by_call)
    print("vtables typed: %s" % (", ".join("%s %d" % (ns, sum(len(x) for x in sl)) for ns, sl in sorted(typed.items())) or "none"))
    print("an indirect call's bound, any address-taken function: %s" % ("%d B" % reach if reach is not UNKNOWN else "unknown: " + why_t))
    entry_re = re.compile(a.entries)
    entries = [fn for fn in fns if entry_re.search(fn.name)]
    by_name = {fn.name: fn for fn in fns}
    base_fns = [by_name.get(n) for n in ("rig.sched.fiberStartNaked", "rig.sched.fiberMain")]
    # fiberMain's own frame, at its call of the fiber's `run`.
    fm = by_name.get("rig.sched.fiberMain")
    fm_depth = max([d for d, _ in fm.icalls] + [d for d, _, _ in fm.islots], default=0) + (8 if arch == "x86_64" else 0) if fm else 0
    start_naked = by_name.get("rig.sched.fiberStartNaked")
    start_depth = (start_naked.own if start_naked else 0) + (8 if arch == "x86_64" else 0)
    files = set(x for x in a.program_files.split(",") if x)
    if not files:
        files = None
    program_files = files or ProgramFiles()
    names = names_of(a.exe, fmt, entries, program_files, {fn.start: fn for fn in fns})
    by_addr = {fn.start: fn for fn in fns}
    for fn in entries:
        if not names[fn.start]:
            names[fn.start] = ", ".join(called_names(fn, by_addr)[:3]) or "?"
    rows = []
    for fn in entries:
        dc, dw, dfo = direct(fn.start)
        rc, rw, rfo = with_taken(fn.start)
        pre = start_depth + fm_depth
        rows.append({"entry": fn.name, "runs": names[fn.start],
                     "direct": None if dc is UNKNOWN else dc + pre, "direct_why": dw, "direct_foreign": sorted(dfo),
                     "resolved": None if rc is UNKNOWN else rc + pre, "resolved_why": rw, "resolved_foreign": sorted(rfo)})
    known = [fn for fn in fns if not fn.why]
    frames = sorted(fns, key=lambda f: -f.own)[: a.top]
    print("%s: %s %s, %d functions, %d with an unknown frame, %d whose address is taken" % (a.exe, arch, fmt, len(fns), len(fns) - len(known), len(taken)))
    print("a task's start: fiberStartNaked %d + fiberMain %d bytes, before its `run`" % (start_depth, fm_depth))
    print()
    print("| task's `run` | runs | bound, pointers unknown | bound, pointers resolved | foreign calls on its paths |")
    print("|---|---|---|---|---|")
    for r in rows:
        d = "%d B" % r["direct"] if r["direct"] is not None else "unknown: " + r["direct_why"]
        x = "%d B" % r["resolved"] if r["resolved"] is not None else "unknown: " + r["resolved_why"]
        fo = r["resolved_foreign"] or r["direct_foreign"]
        f = "%d: %s" % (len(fo), ", ".join(fo[:4]) + (", ..." if len(fo) > 4 else "")) if fo else "none"
        print("| %s | %s | %s | %s | %s |" % (r["entry"], r["runs"], d, x, f))
    known_rows = sorted(r["resolved"] for r in rows if r["resolved"] is not None)
    print()
    print("%d task types: %d bounded with pointers resolved (%s), %d with pointers unknown, %d unknown" % (
        len(rows), len(known_rows), ", ".join("%d" % x for x in known_rows) + " B" if known_rows else "none",
        sum(1 for r in rows if r["direct"] is not None), len(rows) - len(known_rows)))
    print()
    print("the largest frames:")
    for fn in frames:
        print("  %7d  %s" % (fn.own, fn.name))
    unknown = [fn for fn in fns if fn.why]
    if unknown:
        print()
        print("frames unknown (%d), the first 10:" % len(unknown))
        for fn in unknown[:10]:
            print("  %s: %s" % (fn.name, fn.why))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"exe": a.exe, "arch": arch, "rows": rows, "frames": {fn.name: fn.own for fn in fns}, "unknown": {fn.name: fn.why for fn in unknown}}, f, indent=1)


class ProgramFiles:
    """The emitted files of a Rig program: `__rig_main.zig` and the program's
    own modules, not the runtime's nor std's shims nor Zig's."""
    RUNTIME = {"runtime.zig", "sched.zig", "tasks.zig", "net.zig", "alloc.zig", "ordered.zig", "unordered.zig", "split.zig", "table.zig"}

    def __contains__(self, f):
        return f.endswith(".zig") and f not in self.RUNTIME and not f.startswith("__rig_std") and "/" not in f and f not in ("start.zig", "debug.zig", "mem.zig", "fmt.zig", "Thread.zig", "Io.zig", "posix.zig", "heap.zig", "atomic.zig", "math.zig", "array_list.zig", "Threaded.zig", "builtin.zig")


if __name__ == "__main__":
    main()
