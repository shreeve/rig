#!/usr/bin/env python3
"""The stack each function of the root module really reserves.

`_frames.py <file>` prints "<function> <bytes>" for each function
`__rig_main.<function>` in <file>, and for each of the runtime's,
`rig.runtime.<function>` (with that prefix), which is Zig's aarch64 assembly
(`-femit-asm`) or `objdump -d -M intel --no-show-raw-insn` of an x86_64
program. The bytes are what its prologue reserves:

- aarch64: each `sub sp, sp, #N` (`, lsl #12` scales it by 4096), and the
  pair it pushes with `stp ..., [sp, #-N]!`;
- x86_64: each `sub rsp, N`, or `sub rsp, REG` after `mov REG, N`, and the
  end of a probe loop, `sub r11, N`, within its first 24 instructions.

Shared by the tests that compare the compiler's frame counts with real
frames (test/cli/frame_reach.sh).
"""
import re
import sys

ARM_LABEL = re.compile(r'^___rig_main\.([A-Za-z0-9_]+):$|^_(rig\.runtime\.[A-Za-z0-9_.]+):$')
X86_LABEL = re.compile(r'^[0-9a-f]+ <__rig_main\.([A-Za-z0-9_]+)>:$|^[0-9a-f]+ <(rig\.runtime\.[A-Za-z0-9_.]+)>:$')
OTHER = re.compile(r'^([0-9a-f]+ <.*>:|_\S*:)$')


def frames(path):
    out = {}
    fn = None
    count = 0
    regs = {}
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = ARM_LABEL.match(line) or X86_LABEL.match(line)
        if m:
            fn = m.group(1) or m.group(2)
            out[fn] = 0
            count = 0
            regs = {}
            continue
        if OTHER.match(line):
            fn = None
            continue
        if fn is None:
            continue
        t = line.split()
        if not t:
            continue
        if t[0] == '.cfi_endproc':
            fn = None
            continue
        if t[0] == 'sub' and t[1:3] == ['sp,', 'sp,']:
            n = int(t[3].strip('#,'), 0)
            out[fn] += n * 4096 if len(t) > 5 and t[5] == '#12' else n
            continue
        if t[0] == 'stp' and len(t) > 4 and t[3] == '[sp,' and re.match(r'^#-\d+\]!$', t[4]):
            out[fn] += int(t[4][2:-2])
            continue
        # objdump: "addr:\tmnemonic operands".
        if '\t' not in line:
            continue
        count += 1
        if count > 24:
            continue
        ins = line.split('\t')[-1].strip()
        m = re.match(r'^mov\s+(r10d?|r11d?|eax|rax),(0x[0-9a-f]+)$', ins)
        if m:
            regs[m.group(1).rstrip('d').replace('eax', 'rax')] = int(m.group(2), 16)
            continue
        m = re.match(r'^sub\s+rsp,(0x[0-9a-f]+)$', ins)
        if m:
            out[fn] += int(m.group(1), 16)
            continue
        m = re.match(r'^sub\s+rsp,(r10|r11|rax)$', ins)
        if m:
            out[fn] += regs.get(m.group(1), 0)
            continue
        m = re.match(r'^sub\s+r11,(0x[0-9a-f]+)$', ins)
        if m:
            out[fn] += int(m.group(1), 16)
    return out


if __name__ == '__main__':
    for name, size in frames(sys.argv[1]).items():
        print(name, size)
