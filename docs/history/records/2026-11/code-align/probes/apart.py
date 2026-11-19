#!/usr/bin/env python3
"""apart.py IN.o OUT.o: bin/rig's keepCodeApart, for probes: copy a Mach-O
object with its __TEXT,__rig_text section's flags set to S_REGULAR."""
import struct, sys
b = bytearray(open(sys.argv[1], "rb").read())
assert struct.unpack_from("<I", b, 0)[0] == 0xfeedfacf
ncmds = struct.unpack_from("<I", b, 16)[0]; at = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", b, at)
    if cmd == 0x19:
        nsects = struct.unpack_from("<I", b, at + 64)[0]; s = at + 72
        for _ in range(nsects):
            sect, seg = b[s:s+16].rstrip(b"\0"), b[s+16:s+32].rstrip(b"\0")
            if sect == b"__rig_text" and seg == b"__TEXT":
                struct.pack_into("<I", b, s + 64, 0)
            s += 80
    at += size
open(sys.argv[2], "wb").write(b)
