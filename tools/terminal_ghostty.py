#!/usr/bin/env python3
"""Record what Ghostty's terminal shows for the cases of
test/rig/std-terminal-ghostty.rig.test, as their expected results: each
case's bytes go to Ghostty (libghostty-vt at PIN) and to std.terminal,
and both print the screen and cursor the same way (`Terminal.dump`).
TERMINAL_GHOSTTY_FULL=1 test/cli/terminal_ghostty.sh checks the recorded
answers are still Ghostty's.

    tools/terminal_ghostty.py           write test/rig/std-terminal-ghostty.rig.test
    tools/terminal_ghostty.py --check   fail when that file is not what it writes

It needs Ghostty's source, from $GHOSTTY (a git checkout that has PIN) or
cloned from GitHub, and the Zig Ghostty builds with: $ZIG_GHOSTTY, or Zig
0.16.0 as mise installs it. Ghostty is exported at PIN into
.zig-cache/ghostty-PIN, and tools/terminal_ghostty.zig is built against
it under .zig-cache/terminal-ghostty; its first build fetches Ghostty's
dependencies. Ghostty is built without its SIMD paths (`simd = false`,
pure Zig): they are C++ that Zig 0.16's libc++ does not build against
every macOS SDK, and they change Ghostty's speed, not what it shows. It
runs no rig.

A case is in AREAS, the parts of the terminal std.terminal implements;
the file holds only those areas' cases, so a case that fails is a bug,
and an area joins AREAS with the code that implements it.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES_FILE = os.path.join(ROOT, "test", "rig", "std-terminal-ghostty.rig.test")
DUMPER = os.path.join(ROOT, "tools", "terminal_ghostty.zig")
CACHE = os.path.join(ROOT, ".zig-cache")
PIN = "31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2"
GHOSTTY_URL = "https://github.com/ghostty-org/ghostty"

# The areas std.terminal implements, in the file's order.
AREAS = ["print", "control", "cursor", "escape", "parser", "erase", "edit", "scroll"]

# (area, name, cols, rows, bytes): what a program writes to a terminal of
# cols by rows.
CASES = [
    ("print", "print fills the first row", 10, 4, b"hello"),
    ("print", "print wraps at the right margin", 10, 4, b"abcdefghijk"),
    ("print", "a full row leaves a wrap pending", 10, 4, b"abcdefghij"),
    ("print", "carriage return clears a pending wrap", 10, 4, b"abcdefghij\rX"),
    ("print", "line feed keeps the column", 10, 4, b"abc\ndef"),
    ("print", "carriage return and line feed", 10, 4, b"one\r\ntwo\r\nthree"),
    ("print", "vertical tab and form feed are line feeds", 10, 4, b"a\x0bb\x0cc"),
    ("print", "line feed at the bottom scrolls", 10, 3, b"1\r\n2\r\n3\r\n4\r\n5"),
    ("print", "wrapping at the bottom scrolls", 4, 2, b"abcdefghijkl"),
    ("print", "backspace moves left", 10, 4, b"abc\x08X"),
    ("print", "backspace stops at the left margin", 10, 4, b"\x08\x08a"),
    ("print", "backspace with a wrap pending", 4, 2, b"abcd\x08X"),
    ("print", "line feed with a wrap pending", 4, 3, b"abcd\nX"),
    ("print", "printable ASCII", 16, 6, bytes(range(0x20, 0x7F))),
    ("print", "a one-column terminal", 1, 3, b"abc"),
    ("control", "tab moves to the next stop", 20, 2, b"a\tb\tc"),
    ("control", "tab stops at the last column", 20, 2, b"\t\t\t\tX"),
    ("control", "tab with a wrap pending", 8, 2, b"abcdefgh\tX"),
    ("control", "bell and other controls print nothing", 10, 2, b"a\x07\x00\x01\x05\x0e\x0f\x1fb"),
    ("control", "DEL is printed as a character", 10, 2, b"a\x7fb"),
    ("cursor", "CUP moves to a row and column", 10, 4, b"\x1b[2;5HX"),
    ("cursor", "CUP with no parameters goes home", 10, 4, b"abc\r\nde\x1b[HX"),
    ("cursor", "CUP clamps to the screen", 10, 4, b"\x1b[99;99HX"),
    ("cursor", "CUP with zeros is one", 10, 4, b"\x1b[3;3H\x1b[0;0HX"),
    ("cursor", "CUP with only a row", 10, 4, b"\x1b[3HX"),
    ("cursor", "CUP with only a column", 10, 4, b"\x1b[;4HX"),
    ("cursor", "HVP is CUP", 10, 4, b"\x1b[2;3fX"),
    ("cursor", "CUU stops at the top", 10, 4, b"\x1b[3;3H\x1b[5AX"),
    ("cursor", "CUD stops at the bottom", 10, 4, b"\x1b[9BX"),
    ("cursor", "CUF stops at the right edge", 10, 4, b"\x1b[20CX"),
    ("cursor", "CUB stops at the left edge", 10, 4, b"abc\x1b[9DX"),
    ("cursor", "a count of zero moves one", 10, 4, b"\x1b[3;3H\x1b[0A\x1b[0DX"),
    ("cursor", "CNL and CPL go to the first column", 10, 4, b"abc\x1b[2EX\x1b[1FY"),
    ("cursor", "CHA sets the column", 10, 4, b"abc\x1b[7GX"),
    ("cursor", "HPA sets the column", 10, 4, b"abc\x1b[5`X"),
    ("cursor", "VPA sets the row", 10, 4, b"abc\x1b[3dX"),
    ("cursor", "HPR and VPR move right and down", 10, 4, b"a\x1b[3aX\x1b[2eY"),
    ("cursor", "movement clears a pending wrap", 4, 3, b"abcd\x1b[DX"),
    ("cursor", "CUF from a pending wrap", 4, 3, b"abcd\x1b[CX"),
    ("cursor", "CUP clears a pending wrap", 4, 3, b"abcd\x1b[1;1HX"),
    ("cursor", "CHT and CBT move by tab stops", 30, 2, b"\x1b[2IX\x1b[ZY"),
    ("cursor", "CBT stops at the first column", 30, 2, b"abc\x1b[5ZX"),
    ("cursor", "two parameters to CUU do nothing", 10, 4, b"\x1b[3;3H\x1b[1;1AX"),
    ("escape", "IND moves down", 10, 3, b"ab\x1bDX"),
    ("escape", "IND at the bottom scrolls", 10, 2, b"1\r\n2\x1bDX"),
    ("escape", "NEL moves to the next line", 10, 3, b"ab\x1bEX"),
    ("escape", "RI moves up", 10, 3, b"\x1b[3;3H\x1bMX"),
    ("escape", "RI at the top scrolls down", 10, 3, b"1\r\n2\r\n3\x1b[H\x1bMX"),
    ("escape", "HTS sets a tab stop", 20, 2, b"\x1b[4G\x1bH\r\tX"),
    ("escape", "TBC 0 clears the stop at the cursor", 20, 2, b"\x1b[9G\x1b[0g\r\tX"),
    ("escape", "TBC with no parameter does nothing", 20, 2, b"\x1b[9G\x1b[g\r\tX"),
    ("escape", "TBC 3 clears every stop", 20, 2, b"\x1b[3g\tX"),
    ("escape", "DECSC and DECRC save the position", 10, 3, b"ab\x1b7\x1b[3;5HX\x1b8Y"),
    ("escape", "DECRC with nothing saved goes home", 10, 3, b"\x1b[2;2H\x1b8X"),
    ("escape", "DECRC restores a pending wrap", 4, 3, b"abcd\x1b7\x1b[2;1H\x1b8X"),
    ("escape", "an unknown escape is ignored", 10, 2, b"a\x1bQb\x1b(Bc"),
    ("parser", "CAN cancels a sequence", 10, 2, b"a\x1b[2\x18;3HX"),
    ("parser", "SUB cancels a sequence", 10, 2, b"a\x1b[\x1aHX"),
    ("parser", "ESC restarts a sequence", 10, 4, b"\x1b[3\x1b[2;2HX"),
    ("parser", "a control inside CSI runs", 10, 4, b"abc\x1b[2\rCX"),
    ("parser", "a late control inside CSI is dropped", 10, 4, b"abc\x1b[2\x11CX"),
    ("parser", "a private CSI is not a movement", 10, 4, b"\x1b[?5CX"),
    ("parser", "an intermediate makes CSI unknown", 10, 4, b"\x1b[3 CX"),
    ("parser", "a colon makes CSI unknown", 10, 4, b"\x1b[1:2HX"),
    ("parser", "a leading colon is ignored", 10, 4, b"\x1b[:2HX"),
    ("parser", "too many parameters do nothing", 10, 4, b"\x1b[" + b";" * 30 + b"2HX"),
    ("parser", "a huge parameter is clamped", 10, 4, b"\x1b[99999999999CX"),
    ("parser", "OSC is ignored to BEL", 10, 2, b"a\x1b]0;title\x07b"),
    ("parser", "OSC is ignored to ST", 10, 2, b"a\x1b]0;title\x1b\\b"),
    ("parser", "DCS is ignored to ST", 10, 2, b"a\x1bPq#0;1\x1b\\b"),
    ("parser", "APC is ignored to ST", 10, 2, b"a\x1b_Gx=1\x1b\\b"),
    ("parser", "DEL inside CSI is ignored", 10, 4, b"\x1b[2\x7fCX"),
    ("erase", "EL 0 erases to the end of the row", 10, 2, b"abcdefghij\x1b[1;4H\x1b[K"),
    ("erase", "EL 1 erases to the cursor", 10, 2, b"abcdefghij\x1b[1;4H\x1b[1K"),
    ("erase", "EL 2 erases the row", 10, 2, b"abcdefghij\x1b[1;4H\x1b[2K"),
    ("erase", "EL with an unknown parameter", 10, 2, b"abcdefghij\x1b[1;4H\x1b[5K"),
    ("erase", "EL clears a pending wrap", 4, 2, b"abcd\x1b[KX"),
    ("erase", "selective EL erases", 10, 2, b"abcdefghij\x1b[1;4H\x1b[?K"),
    ("erase", "ED 0 erases to the end of the screen", 10, 4, b"abcdefghij" * 4 + b"\x1b[2;4H\x1b[J"),
    ("erase", "ED 1 erases to the cursor", 10, 4, b"abcdefghij" * 4 + b"\x1b[2;4H\x1b[1J"),
    ("erase", "ED 2 erases the screen", 10, 4, b"abcdefghij" * 4 + b"\x1b[2;4H\x1b[2J"),
    ("erase", "ED 3 keeps the screen", 10, 4, b"abcdefghij" * 4 + b"\x1b[2;4H\x1b[3J"),
    ("erase", "ED with a wrap pending", 4, 2, b"abcd\x1b[JX"),
    ("erase", "ECH erases cells", 10, 2, b"abcdefghij\x1b[1;3H\x1b[3X"),
    ("erase", "ECH with no count erases one", 10, 2, b"abcdefghij\x1b[1;3H\x1b[X"),
    ("erase", "ECH of zero erases one", 10, 2, b"abcdefghij\x1b[1;3H\x1b[0X"),
    ("erase", "ECH stops at the row's end", 10, 2, b"abcdefghij\x1b[1;8H\x1b[9X"),
    ("erase", "ECH clears a pending wrap", 4, 2, b"abcd\x1b[XX"),
    ("erase", "DECALN fills the screen with E", 6, 3, b"ab\x1b[2;3r\x1b[3;3H\x1b#8"),
    ("edit", "ICH inserts blanks", 10, 2, b"abcdefghij\x1b[1;3H\x1b[2@"),
    ("edit", "ICH with no count inserts one", 10, 2, b"abcdef\x1b[1;3H\x1b[@X"),
    ("edit", "ICH past the row's end", 10, 2, b"abcdefghij\x1b[1;3H\x1b[20@"),
    ("edit", "ICH clears a pending wrap", 4, 2, b"abcd\x1b[@X"),
    ("edit", "DCH deletes cells", 10, 2, b"abcdefghij\x1b[1;3H\x1b[2P"),
    ("edit", "DCH of zero does nothing", 10, 2, b"abcdefghij\x1b[1;3H\x1b[0P"),
    ("edit", "DCH past the row's end", 10, 2, b"abcdefghij\x1b[1;3H\x1b[20P"),
    ("edit", "DCH clears a pending wrap", 4, 2, b"abcd\x1b[PX"),
    ("edit", "IL inserts lines", 10, 4, b"1\r\n2\r\n3\r\n4\x1b[2;3H\x1b[LX"),
    ("edit", "IL of many clears to the bottom", 10, 4, b"1\r\n2\r\n3\r\n4\x1b[2;3H\x1b[9LX"),
    ("edit", "IL of zero does nothing", 10, 4, b"1\r\n2\r\n3\r\n4\x1b[2;3H\x1b[0LX"),
    ("edit", "DL deletes lines", 10, 4, b"1\r\n2\r\n3\r\n4\x1b[2;3H\x1b[MX"),
    ("edit", "DL of many clears to the bottom", 10, 4, b"1\r\n2\r\n3\r\n4\x1b[2;3H\x1b[9MX"),
    ("edit", "IL inside the scroll region", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[3;2H\x1b[LX"),
    ("edit", "DL inside the scroll region", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[2;2H\x1b[MX"),
    ("edit", "IL outside the scroll region does nothing", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[5;2H\x1b[LX"),
    ("edit", "IL clears a pending wrap", 4, 3, b"abcd\x1b[LX"),
    ("scroll", "DECSTBM homes the cursor", 10, 5, b"\x1b[3;3H\x1b[2;4rX"),
    ("scroll", "LF at the bottom margin scrolls the region", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[4;1H\nX"),
    ("scroll", "LF below the region moves down", 10, 5, b"1\r\n2\x1b[2;3r\x1b[4;1H\nX"),
    ("scroll", "LF at the last row below the region", 10, 5, b"1\r\n2\x1b[2;3r\x1b[5;1H\nX"),
    ("scroll", "RI at the top margin scrolls the region down", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[2;1H\x1bMX"),
    ("scroll", "RI at the top margin keeps a pending wrap", 4, 4, b"1\r\n2\r\n3\x1b[2;3r\x1b[2;1Habcd\x1bMX"),
    ("scroll", "CUU stops at the top margin", 10, 5, b"\x1b[2;4r\x1b[4;1H\x1b[9AX"),
    ("scroll", "CUD stops at the bottom margin", 10, 5, b"\x1b[2;4r\x1b[2;1H\x1b[9BX"),
    ("scroll", "CUU above the region stops at the top", 10, 5, b"\x1b[3;4r\x1b[2;1H\x1b[9AX"),
    ("scroll", "CUD below the region stops at the bottom", 10, 5, b"\x1b[2;3r\x1b[4;1H\x1b[9BX"),
    ("scroll", "CUP ignores the region", 10, 5, b"\x1b[2;3r\x1b[5;5HX"),
    ("scroll", "a region of one row is ignored", 10, 5, b"1\r\n2\r\n3\x1b[3;3r\x1b[5;1H\nX"),
    ("scroll", "DECSTBM with no parameters resets", 10, 4, b"\x1b[2;3r\x1b[r1\r\n2\r\n3\r\n4\r\n5"),
    ("scroll", "a bottom past the screen is the last row", 10, 4, b"\x1b[2;99r1\r\n2\r\n3\r\n4\r\n5"),
    ("scroll", "SU scrolls the region up", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[3;3H\x1b[SX"),
    ("scroll", "SD scrolls the region down", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[3;3H\x1b[2TX"),
    ("scroll", "SU of many clears the region", 10, 5, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[9S"),
    ("scroll", "SU keeps a pending wrap", 4, 3, b"1\r\nabcd\x1b[SX"),
    ("scroll", "SU of zero", 10, 3, b"1\r\n2\r\n3\x1b[0S"),
    ("scroll", "SD of zero", 10, 3, b"1\r\n2\r\n3\x1b[0T"),
    ("scroll", "wrapping at the bottom margin scrolls the region", 4, 4, b"1\r\n2\r\n3\r\n4\x1b[1;3r\x1b[3;1Habcdef"),
]


def zig_for_ghostty():
    z = os.environ.get("ZIG_GHOSTTY")
    if z:
        return z
    try:
        where = subprocess.run(["mise", "where", "zig@0.16.0"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("terminal_ghostty: set ZIG_GHOSTTY to Zig 0.16.0, or install it with mise")
    return os.path.join(where, "zig")


def ghostty_tree():
    """Ghostty's source at PIN, exported once into the cache."""
    tree = os.path.join(CACHE, "ghostty-" + PIN[:12])
    if os.path.exists(os.path.join(tree, "build.zig")):
        return tree
    src = os.environ.get("GHOSTTY")
    tmp = None
    if not src:
        tmp = tempfile.mkdtemp(prefix="ghostty-clone-")
        subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", GHOSTTY_URL, tmp], check=True)
        src = tmp
    os.makedirs(tree + ".part", exist_ok=True)
    archive = subprocess.run(["git", "-C", src, "archive", PIN], capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", tree + ".part"], input=archive, check=True)
    os.replace(tree + ".part", tree)
    if tmp:
        shutil.rmtree(tmp)
    return tree


def dumper():
    """tools/terminal_ghostty.zig built against Ghostty; its path."""
    tree = ghostty_tree()
    build = os.path.join(CACHE, "terminal-ghostty")
    os.makedirs(build, exist_ok=True)
    zon = """.{
    .name = .terminal_ghostty,
    .version = "0.0.0",
    .fingerprint = FINGERPRINT,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{ .ghostty = .{ .path = "TREE" } },
    .paths = .{""},
}
""".replace("TREE", os.path.relpath(tree, build))
    zig_build = """const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "DUMPER" },
        .target = b.standardTargetOptions(.{}),
        .optimize = .ReleaseSafe,
    });
    if (b.lazyDependency("ghostty", .{ .simd = false })) |dep| mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    b.installArtifact(b.addExecutable(.{ .name = "terminal_ghostty", .root_module = mod }));
}
""".replace("DUMPER", DUMPER)
    with open(os.path.join(build, "build.zig"), "w") as f:
        f.write(zig_build)
    with open(os.path.join(build, "build.zig.zon"), "w") as f:
        f.write(zon.replace("FINGERPRINT", fingerprint(build, zon, zig_build)))
    run = subprocess.run([zig_for_ghostty(), "build", "install"], cwd=build, capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit("terminal_ghostty: building the dumper failed:\n" + run.stderr)
    return os.path.join(build, "zig-out", "bin", "terminal_ghostty")


def fingerprint(build, zon, zig_build):
    """The fingerprint Zig wants for the package name: it names it when given none."""
    with open(os.path.join(build, "build.zig"), "w") as f:
        f.write(zig_build)
    with open(os.path.join(build, "build.zig.zon"), "w") as f:
        f.write(zon.replace("    .fingerprint = FINGERPRINT,\n", ""))
    out = subprocess.run([zig_for_ghostty(), "build", "--help"], cwd=build, capture_output=True, text=True).stderr
    for word in out.split():
        if word.startswith("0x"):
            return word.rstrip(",.")
    sys.exit("terminal_ghostty: Zig named no fingerprint:\n" + out)


def answers(cases):
    """Ghostty's dump of each case, in order."""
    exe = dumper()
    with tempfile.NamedTemporaryFile(suffix=".cases", delete=False) as f:
        for _, _, cols, rows, data in cases:
            f.write(b"case %d %d %d\n" % (cols, rows, len(data)) + data + b"\n")
        path = f.name
    try:
        out = subprocess.run([exe, path], capture_output=True, check=True).stdout.decode("utf-8")
    finally:
        os.unlink(path)
    dumps = out.split("end\n")
    if dumps[-1] != "" or len(dumps) - 1 != len(cases):
        sys.exit("terminal_ghostty: the dumper printed %d dumps for %d cases" % (len(dumps) - 1, len(cases)))
    return [d.rstrip("\n") for d in dumps[:-1]]


def literal(data):
    """A Rig string literal of `data`: printable ASCII as itself, every other byte escaped."""
    out = []
    for b in data:
        if b == 0x22 or b == 0x5C:
            out.append("\\" + chr(b))
        elif 0x20 <= b < 0x7F:
            out.append(chr(b))
        else:
            out.append("\\x%02x" % b)
    return '"' + "".join(out) + '"'


def text(cases, dumps):
    out = [
        "# std: std.terminal against Ghostty (libghostty-vt at %s), which" % PIN[:12],
        "# defines what it shows. Written by tools/terminal_ghostty.py from",
        "# Ghostty's answers: run it to write this file again after a change to",
        "# its cases.",
        "",
        "use std.terminal",
    ]
    for (area, name, cols, rows, data), dump in zip(cases, dumps):
        out.append("")
        out.append('test "%s", \'\'\'' % name)
        out.extend("  " + line for line in dump.split("\n"))
        out.append("'''")
        out.append("  t = terminal.Terminal.new(%d, %d)" % (cols, rows))
        out.append("  !t.feed(%s)" % literal(data))
        out.append("  print(t.dump())")
    return "\n".join(out) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--check", action="store_true", help="fail when the file is not what this writes")
    args = p.parse_args()
    cases = [c for area in AREAS for c in CASES if c[0] == area]
    want = text(cases, answers(cases))
    if args.check:
        have = open(CASES_FILE).read() if os.path.exists(CASES_FILE) else ""
        if have != want:
            sys.exit("test/rig/std-terminal-ghostty.rig.test is not what tools/terminal_ghostty.py writes")
        return
    with open(CASES_FILE, "w") as f:
        f.write(want)
    print("wrote %s: %d cases" % (os.path.relpath(CASES_FILE, ROOT), len(cases)))


if __name__ == "__main__":
    main()
