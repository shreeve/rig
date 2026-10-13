#!/usr/bin/env python3
"""Build std/json.rig benchmark programs, with hand patches to the emitted Zig.

usage: build.py OUT FILES VARIANTS [--dsym] [--fast]

  FILES     comma-separated corpus files (test/json/data/simd-json/NAME.json)
  VARIANTS  comma-separated; each is `base` or patch names joined by `+`
            (patches/NAME.py, each a `patch(json_zig) -> json_zig`), led
            optionally by `src:NAME`, a parser in src/NAME.rig

Rig emits the package once per file (rig build --release, kept); each
variant is a copy of it with its patches applied, built with the same
`zig build-exe -Osafe` rig runs. The programs land in OUT/FILE-VARIANT/prog,
the layout bench-json --out uses, so bench/json/timers/*.py read them too.
--dsym keeps a .dSYM beside each program (macOS), for profiling.

These patches only measure what a lowering would give. Never ship one: a
speedup lands as a portable, safe Rig operation (docs/json/OPCODE-STUDY.md).
"""
import importlib.util, os, platform, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, "bench", "json"))
RIG = os.environ.get("RIG", os.path.join(ROOT, "bin", "rig"))
DATA = os.path.join(ROOT, "test", "json", "data", "simd-json")


def bench_json():
    """bench-json's MAIN and rig_literal, so the programs are the same."""
    spec = importlib.util.spec_from_loader("bench_json", loader=None)
    mod = importlib.util.module_from_spec(spec)
    path = os.path.join(ROOT, "bench", "json", "bench-json")
    mod.__file__ = path
    src = open(path).read()
    src = src[: src.index("\nmain()")]
    exec(compile(src, "bench-json", "exec"), mod.__dict__)
    return mod


def load_patch(name):
    if os.path.join(HERE, "patches") not in sys.path:
        sys.path.insert(0, os.path.join(HERE, "patches"))
    path = os.path.join(HERE, "patches", name + ".py")
    spec = importlib.util.spec_from_file_location("patch_" + name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def apply(pkg, variant):
    """Apply the patches of `variant` to the package directory `pkg`."""
    if variant == "base":
        return
    p = os.path.join(pkg, "json.zig")
    s = open(p).read()
    for name in variant.split("+"):
        mod = load_patch(name)
        s = mod.patch(s)
        if hasattr(mod, "patch_runtime"):
            r = os.path.join(pkg, "rig", "runtime.zig")
            text = mod.patch_runtime(open(r).read())
            open(r, "w").write(text)
    open(p, "w").write(s)


def run(cmd, env=None, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd)
    if p.returncode != 0:
        sys.exit("failed: %s\n%s%s" % (" ".join(cmd), p.stdout[-3000:], p.stderr[-6000:]))
    return p.stdout + p.stderr


def main():
    if sys.argv[1] == "--apply":  # opzig.sh: patch one emitted package in place
        apply(sys.argv[2], sys.argv[3])
        return
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dsym = "--dsym" in sys.argv
    mode = "-Ofast" if "--fast" in sys.argv else "-Osafe"
    out, files, variants = os.path.abspath(args[0]), args[1].split(","), args[2].split(",")
    os.makedirs(out, exist_ok=True)
    jobs = os.environ.get("CPUQ_CORES", "2")
    zig = os.environ.get("ZIG", "zig")
    bj = bench_json()
    for f in files:
        data = open(os.path.join(DATA, f + ".json"), "rb").read()
        for v in variants:
            d = os.path.join(out, "%s-%s" % (f, v))
            exe = os.path.join(d, "prog")
            if os.path.exists(exe):
                continue
            # A first part `src:NAME` takes the parser from src/NAME.rig
            # (a change to std.json itself) in place of std/json.rig.
            parts = v.split("+")
            srcname = parts[0][4:] if parts[0].startswith("src:") else None
            patches = "+".join(parts[1:] if srcname else parts) or "base"
            pkg0 = emit(out, f, data, srcname, bj)
            pkg = os.path.join(d, "pkg")
            shutil.rmtree(pkg, ignore_errors=True)
            shutil.copytree(pkg0, pkg)
            apply(pkg, patches)
            cache = os.path.join(d, ".zc")
            run([zig, "build-exe", mode, "-j" + jobs, "--cache-dir", cache, "-femit-bin=" + exe + ".tmp",
                 os.path.join(pkg, "__rig_main.zig")], cwd=pkg)
            if dsym and platform.system() == "Darwin":
                run(["dsymutil", exe + ".tmp", "-o", exe + ".dSYM"])
            shutil.rmtree(cache, ignore_errors=True)
            os.rename(exe + ".tmp", exe)
            print("built", f, v, flush=True)


def emit(out, f, data, srcname, bj):
    """The package rig emits for file `f` with parser `srcname` (or std.json), once."""
    src_dir = os.path.join(out, "_src-" + f + ("-" + srcname if srcname else ""))
    pkg0 = os.path.join(src_dir, "out")
    if not os.path.exists(os.path.join(pkg0, "json.zig")):
        os.makedirs(src_dir, exist_ok=True)
        json_rig = os.path.join(HERE, "src", srcname + ".rig") if srcname else \
            os.environ.get("JSON", os.path.join(ROOT, "std", "json.rig"))
        shutil.copy(json_rig, os.path.join(src_dir, "json.rig"))
        open(os.path.join(src_dir, "main.rig"), "w").write(bj.MAIN.replace("@SRC@", bj.rig_literal(data)))
        env = dict(os.environ, RIG_OUT_DIR=pkg0)
        # `rig emit` writes the whole package to RIG_OUT_DIR.
        run([RIG, "emit", os.path.join(src_dir, "main.rig")], env=env)
        shutil.rmtree(os.path.join(pkg0, ".zig-cache"), ignore_errors=True)
    return pkg0


main()
