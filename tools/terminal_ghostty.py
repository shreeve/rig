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
AREAS = ["print"]

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
