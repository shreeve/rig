#!/usr/bin/env python3
"""The safety checks that survive optimization in a Rig module, per line.

usage: inventory.py PKG MODULE.zig [TARGET...]

PKG is a package rig emitted (`RIG_OUT_DIR=PKG rig build --release ...`),
MODULE.zig the emitted file to charge checks to (`json.zig` for a local
`use json`, `__rig_std_json.zig` for `use std.json`). Each TARGET is
`zig-target:cpu`; the default is aarch64-macos:apple_m1 and
x86_64-linux-gnu:meteorlake. For each target the package's root is built
`-O ReleaseSafe` to an object with debug info and disassembled.

LLVM merges the panic calls of one kind into one call per function, so a
check is a conditional branch into a panic block: the instructions that
end in a call to a panic routine, back to the previous transfer of
control. Each such branch is looked up in DWARF (`llvm-dwarfdump --lookup
--show-parents`) and charged to the innermost line of MODULE.zig in its
inline chain. The tools come from Xcode (`xcrun`), so this runs on macOS.
"""
import collections, os, re, subprocess, sys, tempfile

PANIC = re.compile(r"[Pp]anic|integerOverflow|integerOutOfBounds|outOfBounds|startGreaterThanEnd|castTruncatedData|"
                   r"negativeToUnsigned|shlOverflow|shrOverflow|divideByZero|unwrapNull|corruptSwitch|reachedUnreachable|"
                   r"inactiveUnionField|memcpy|forLenMismatch|exactDivisionRemainder|copyLenMismatch|noreturnReturned|"
                   r"incorrectAlignment|\boom\b")
LABEL = re.compile(r"^([0-9a-f]+) <(.*)>:$")
INSN = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
RELOC = re.compile(r"^\s+[0-9a-f]+:\s+(ARM64_RELOC|R_X86)\S*\s+(\S.*)$")
UNCOND = {"b", "ret", "br", "jmp", "ud2", "brk"}

def tool(name):
    return subprocess.run(["xcrun", "-f", name], capture_output=True, text=True, check=True).stdout.strip()

def branch_target(mn, ops):
    if mn.startswith("b.") or mn in ("cbz", "cbnz", "tbz", "tbnz") or (mn.startswith("j") and mn != "jmp"):
        m = re.search(r"0x([0-9a-f]+)", ops)
        return int(m.group(1), 16) if m else None
    return None

def checks_of(obj, od):
    # Symbols by (section, offset), for x86's section-relative relocations.
    syms = {}
    for l in subprocess.run([od, "-t", obj], capture_output=True, text=True).stdout.split("\n"):
        m = re.match(r"^([0-9a-f]+)\s.*?\s(\S+)\s+[0-9a-f]+\s+(.+)$", l)
        if m: syms[(m.group(2).rstrip("."), int(m.group(1), 16))] = m.group(3)
    def resolve(t):
        m = re.match(r"^(\.text[^+]*)\+0x([0-9a-f]+)$", t)
        return syms.get((m.group(1).rstrip("."), int(m.group(2), 16) + 4), t) if m else t
    code, cur = collections.defaultdict(list), None
    dis = subprocess.run([od, "-d", "-r", "--no-show-raw-insn", obj], capture_output=True, text=True).stdout
    for line in dis.split("\n"):
        m = LABEL.match(line)
        if m:
            cur = m.group(2)
            continue
        if cur is None: continue
        r = RELOC.match(line)
        if r:
            if code[cur] and code[cur][-1][1] in ("bl", "call"):
                code[cur][-1][3] = resolve(r.group(2).strip())
            continue
        m = INSN.match(line)
        if m:
            # AT&T spells x86's call, ret and jmp with a size suffix.
            mn = {"callq": "call", "retq": "ret", "jmpq": "jmp"}.get(m.group(2), m.group(2))
            code[cur].append([int(m.group(1), 16), mn, m.group(3), None])
    found = []
    for ins in code.values():
        blocks = []
        for i, (a, mn, ops, tgt) in enumerate(ins):
            if mn in ("bl", "call") and tgt and PANIC.search(tgt):
                j = i
                while j > 0 and not (ins[j - 1][1] in UNCOND or ins[j - 1][1] in ("bl", "call")
                                     or branch_target(ins[j - 1][1], ins[j - 1][2]) is not None):
                    j -= 1
                blocks.append((ins[j][0], a, tgt))
        for a, mn, ops, _ in ins:
            t = branch_target(mn, ops)
            if t is None: continue
            for s, e, routine in blocks:
                if s <= t <= e:
                    found.append((a, routine))
                    break
    return found

def chain(dd, obj, addr):
    out = subprocess.run([dd, "--lookup=0x%x" % addr, "--show-parents", obj], capture_output=True, text=True).stdout
    frames = []
    for blk in re.split(r"\n(?=0x[0-9a-f]+:\s+DW_TAG_)", out):
        if "DW_TAG_inlined_subroutine" in blk or "DW_TAG_subprogram" in blk:
            nm = (re.search(r'DW_AT_(?:linkage_)?name\s+\("([^"]+)"\)', blk)
                  or re.search(r'DW_AT_abstract_origin\s+\(0x[0-9a-f]+ "([^"]+)"\)', blk))
            cf = re.search(r'DW_AT_call_file\s+\("([^"]+)"\)', blk)
            cl = re.search(r"DW_AT_call_line\s+\((\d+)\)", blk)
            frames.append((nm.group(1) if nm else "?", cf.group(1) if cf else None, int(cl.group(1)) if cl else None))
    li = re.search(r"Line info: file '([^']+)', line (\d+)", out)
    return frames, (li.group(1), int(li.group(2))) if li else (None, None)

def report(pkg, module, target, cpu, tmp):
    dd, od = tool("llvm-dwarfdump"), tool("llvm-objdump")
    obj = os.path.join(tmp, "%s.o" % target)
    root = [f for f in os.listdir(pkg) if f == "__rig_main.zig"][0]
    subprocess.run(["zig", "build-obj", "-O", "ReleaseSafe", "-target", target, "-mcpu", cpu, "-femit-bin=" + obj, root],
                   cwd=pkg, check=True, env=dict(os.environ, ZIG_LOCAL_CACHE_DIR=os.path.join(tmp, "zc")))
    src = open(os.path.join(pkg, module)).read().split("\n")
    fn_at, name = {}, "?"
    for i, l in enumerate(src, 1):
        m = re.match(r"\s*(?:pub )?(?:inline )?fn (\w+)", l)
        if m: name = m.group(1)
        fn_at[i] = name
    by_line, detail = collections.Counter(), collections.defaultdict(collections.Counter)
    for addr, routine in checks_of(obj, od):
        frames, inner = chain(dd, obj, addr)
        jline, via = None, module
        if inner[0] and inner[0].endswith(module) and inner[1]:
            jline = inner[1]
        else:
            via = re.sub(r"__func_\d+", "", frames[-1][0]) if frames else "?"
            for _, cf, cl in reversed(frames):
                if cf and cf.endswith(module):
                    jline = cl
                    break
        if not jline: continue
        kind = re.sub(r"__func_\d+", "", re.sub(r"^_*debug\.FullPanic\(\(function '[^']*'\)\)\.", "", routine.strip('"').lstrip("_")))
        by_line[jline] += 1
        detail[jline]["%s <- %s" % (kind, via)] += 1
    per_fn = collections.Counter()
    for ln, n in by_line.items(): per_fn[fn_at.get(ln, "?")] += n
    print("## %s (%s): %d checks on %s lines" % (target, cpu, sum(by_line.values()), module))
    print("by function: " + ", ".join("%s %d" % kv for kv in per_fn.most_common()))
    for ln, n in sorted(by_line.items()):
        print("%5d  %-20s %2d  %s" % (ln, fn_at.get(ln, "?"), n, src[ln - 1].strip()[:100]))
        for k, c in detail[ln].most_common():
            print("%31s %2d  %s" % ("", c, k))
    print()

def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    pkg, module = sys.argv[1], sys.argv[2]
    targets = sys.argv[3:] or ["aarch64-macos:apple_m1", "x86_64-linux-gnu:meteorlake"]
    with tempfile.TemporaryDirectory() as tmp:
        for t in targets:
            target, cpu = t.split(":")
            report(pkg, module, target, cpu, tmp)

main()
