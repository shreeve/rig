#!/usr/bin/env python3
"""Check Rig against the next Zig, a pinned nightly, while Rig itself stays
on Zig 0.17.0 (docs/internals/zig-0.17.md, "Checking the next Zig").

    tools/zig-next.py [--bench] [--fetch-only]

The nightly is PIN below, for the platforms in SHA256. Its tarball is kept
in $RIG_ZIG_NEXT (default ~/.cache/rig-zig-next), fetched from
ziglang.org/builds only when absent there and used only when its sha256
is the pinned one: ziglang.org keeps only recent nightlies, so the mirror
is what keeps a pin buildable. The check runs in a copy of the commit
checked out (`git archive HEAD`, under the mirror's trees/), so this
checkout's bin/, .zig-cache, and .swarm stay 0.17's; uncommitted changes
are not in it. Its suite builds in the mirror's build-store/ unless
RIG_BUILD_STORE names another. With the nightly first on PATH and in $ZIG, it builds rig
(`zig build`), then runs the core suite (`swarm test/rig.rip -q`) unless
the build failed, and reports the first errors, and the failed cases by
test file. `--bench` also times bench/terminal's rig-fast built with each
Zig, the copy's with the nightly and this checkout's with 0.17, runs of
the two interleaved and counted in CPU cycles on macOS, and checks that
both end on the same screen.
Exit status: 0 when rig builds and the suite passes, else 1.

To move the pin: take a newer nightly's version and sha256s from
https://ziglang.org/download/index.json (`master`), set PIN and SHA256,
and run this; then record what changed in the PR that moves it.
"""
import argparse
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

PIN = "0.18.0-dev.362+705a6b4ef"
# platform -> sha256 of zig-PLATFORM-PIN.tar.xz
SHA256 = {
    "aarch64-macos": "57151d70a2d622e05d3bda7ddd34f8cf6af2c74eb64221ff84784856eeec7ce5",
    "x86_64-macos": "11092a08ba7f025f6cca952b090be15546e7d8f6f6f7f5dcbcbfe2ef3bd9167e",
    "aarch64-linux": "8af12342aafac082e4a15e8d969267a06849f43af36f5caec63e2d92c9983214",
    "x86_64-linux": "8f777ee3ef3cbeffa763bff45ef1efa36fa37d3e900da418f3c218a35b7aaa46",
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIRROR = os.environ.get("RIG_ZIG_NEXT") or os.path.expanduser("~/.cache/rig-zig-next")


def plat():
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "AMD64": "x86_64"}.get(platform.machine())
    system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system())
    key = "%s-%s" % (arch, system)
    if key not in SHA256:
        sys.exit("zig-next: no pinned nightly for %s" % key)
    return key


def nightly():
    """The pinned nightly's zig, from the mirror: fetched when absent,
    checked against its sha256, and unpacked once."""
    key = plat()
    name = "zig-%s-%s" % (key, PIN)
    home = os.path.join(MIRROR, PIN)
    os.makedirs(home, exist_ok=True)
    tarball = os.path.join(home, name + ".tar.xz")
    if not os.path.exists(tarball):
        url = "https://ziglang.org/builds/" + name + ".tar.xz"
        print("zig-next: fetching", url)
        try:
            with urllib.request.urlopen(url) as r, open(tarball + ".part", "wb") as f:
                shutil.copyfileobj(r, f)
        except OSError as e:
            sys.exit("zig-next: %s is not on ziglang.org (%s); put the tarball at %s, or move the pin" % (name, e, tarball))
        os.replace(tarball + ".part", tarball)
    with open(tarball, "rb") as f:
        got = hashlib.sha256(f.read()).hexdigest()
    if got != SHA256[key]:
        sys.exit("zig-next: %s has sha256 %s, not the pinned %s" % (tarball, got, SHA256[key]))
    zig = os.path.join(home, name, "zig")
    if not os.path.exists(zig):
        with tarfile.open(tarball) as t:
            t.extractall(home, filter="data")
    return zig


def tree():
    """A copy of the commit checked out, made once a commit, from this
    Rig checkout's repository (tools/gitdir), never one enclosing it."""
    r = subprocess.run([os.path.join(ROOT, "tools", "gitdir"), "zig-next"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(r.stderr.strip())
    rev = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    path = os.path.join(MIRROR, "trees", rev[:12])
    if not os.path.exists(os.path.join(path, "build.zig")):
        os.makedirs(path + ".part", exist_ok=True)
        archive = subprocess.run(["git", "archive", "HEAD"], cwd=ROOT, capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", path + ".part"], input=archive, check=True)
        os.replace(path + ".part", path)
    if subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT, capture_output=True, text=True).stdout.strip():
        print("zig-next: uncommitted changes are not in the copy, which is HEAD", rev[:12])
    return path


def nexus():
    """Nexus, which generates src/parser.zig: $NEXUS, else nexus/bin/nexus
    in a parent directory of this checkout, as build.zig looks for it (the
    copy is elsewhere, so it is named for the build)."""
    if os.environ.get("NEXUS"):
        return os.environ["NEXUS"]
    d = ROOT
    while d != os.path.dirname(d):
        d = os.path.dirname(d)
        path = os.path.join(d, "nexus", "bin", "nexus")
        if os.access(path, os.X_OK):
            return path
    sys.exit("zig-next: Nexus not found above %s; set NEXUS" % ROOT)


def with_zig(zig):
    env = dict(os.environ)
    env["PATH"] = os.path.dirname(zig) + os.pathsep + env.get("PATH", "")
    env["ZIG"] = zig
    env["NEXUS"] = nexus()
    # The copy has no repository, so its suite builds in a store of the
    # mirror's own, apart from 0.17's.
    env.setdefault("RIG_BUILD_STORE", os.path.join(MIRROR, "build-store"))
    return env


def first_errors(text, n=15):
    """The distinct error lines of a Zig build's output, the first `n`, and their count."""
    seen = []
    for line in text.splitlines():
        m = re.search(r"(\S+:\d+:\d+): error: (.*)", line)
        if m and m.group(0) not in seen:
            seen.append(m.group(0))
    return len(seen), seen[:n]


def build(path, env):
    print("== build: zig build (rig, with %s)" % PIN, flush=True)
    r = subprocess.run(["zig", "build"], cwd=path, env=env, capture_output=True, text=True)
    if r.returncode == 0:
        print("rig builds")
        return True
    count, lines = first_errors(r.stderr)
    print("rig does not build: %d distinct errors%s" % (count, ", the first:" if lines else ""))
    for line in lines:
        print("  " + line.replace(path + "/", ""))
    if not lines:
        print("\n".join("  " + l for l in r.stderr.strip().splitlines()[-15:]))
    return False


def suite(path, env):
    print("== suite: swarm test/rig.rip -q (the core, with %s)" % PIN, flush=True)
    r = subprocess.run(["swarm", "test/rig.rip", "-q"], cwd=path, env=env, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    died = [l.strip() for l in out.splitlines() if re.match(r"\s+\S+\.\S+: ", l)]
    summary = [l for l in out.splitlines() if "jobs by" in l]
    print(summary[-1] if summary else out.splitlines()[-1] if out else "(no output)")
    if r.returncode == 0 and not died:
        print("the core suite passes")
        return True
    files = {}
    for l in died:
        files[l.split(".")[0]] = files.get(l.split(".")[0], 0) + 1
    print("%d cases died: %s" % (len(died), ", ".join("%s %d" % kv for kv in sorted(files.items(), key=lambda kv: -kv[1]))))
    for l in died[:12]:
        print("  " + l[:220])
    if not died:
        print("\n".join("  " + l for l in out.splitlines()[-15:]))
    return False


def run_cost(exe, corpus, reps):
    """(cost, screen hash) of one run of a bench/terminal binary: CPU cycles
    where /usr/bin/time -l reports them (macOS), which other work on the
    machine barely moves, else the nanoseconds the binary prints."""
    cmd = [exe, corpus, str(reps), "120", "40"]
    if platform.system() == "Darwin":
        r = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True)
        m = re.search(r"(\d+)\s+cycles elapsed", r.stderr)
        return int(m.group(1)), r.stdout.split()[1]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ns, check = r.stdout.split()
    return int(ns), check


def bench(path, env):
    """bench/terminal's rig-fast built with each Zig (the copy's with the
    nightly, this checkout's with its own), timed run against run, each
    corpus's runs interleaved, the least of seven counting; and whether
    both end on the same screen."""
    print("== bench: bench/terminal rig-fast, interleaved", flush=True)
    if not os.path.exists(os.path.join(ROOT, "bin", "rig")):
        # This checkout's own rig, with its own Zig, for the 0.17 side.
        subprocess.run(["zig", "build"], cwd=ROOT, check=True)
    sides = []
    for label, cwd, e in (("0.17", ROOT, dict(os.environ)), ("next", path, env)):
        r = subprocess.run(["bench/terminal/bench-terminal", "--variants", "rig-fast", "--reps", "1", "--ms", "50"], cwd=cwd, env=e, capture_output=True, text=True)
        if r.returncode != 0:
            print("bench/terminal failed with %s:\n%s" % (label, (r.stderr or r.stdout)[-1500:]))
            return
        sides.append((label, os.path.join(cwd, ".zig-cache", "terminal-bench")))
    unit = "Mcycles" if platform.system() == "Darwin" else "ms"
    print("%-10s %12s %12s %8s  %s" % ("corpus", "Zig 0.17", "next", "change", "screens"))
    for name in sorted(os.listdir(os.path.join(sides[0][1], "data"))):
        corpus = os.path.join(sides[0][1], "data", name)
        best, checks = {}, {}
        for _ in range(7):
            for label, home in sides:
                cost, check = run_cost(os.path.join(home, "rig-fast"), corpus, 10)
                best[label] = min(best.get(label, cost), cost)
                checks[label] = check
        a, b = best["0.17"] / 1e6, best["next"] / 1e6
        print("%-10s %8.0f %-3s %8.0f %-3s %+7.1f%%  %s" % (name.split("-120x")[0], a, unit[:3], b, unit[:3], (b / a - 1) * 100,
                                                        "same" if checks["0.17"] == checks["next"] else "DIFFER"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--bench", action="store_true", help="also time bench/terminal built with both Zigs")
    ap.add_argument("--fetch-only", action="store_true", help="only fetch and check the pinned nightly")
    args = ap.parse_args()
    zig = nightly()
    version = subprocess.run([zig, "version"], capture_output=True, text=True).stdout.strip()
    print("zig-next: %s at %s" % (version, zig))
    if version != PIN:
        sys.exit("zig-next: the nightly says it is %s, not %s" % (version, PIN))
    if args.fetch_only:
        return
    path = tree()
    print("zig-next: checking a copy of HEAD at", path, flush=True)
    env = with_zig(zig)
    ok = build(path, env) and suite(path, env)
    if args.bench and os.path.exists(os.path.join(path, "bin", "rig")):
        bench(path, env)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
