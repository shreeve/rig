"""A grid's program is built again only when something its build reads
changed: a stamp beside the executable holds a hash of every input (the
program's source, the compiler that builds it, Zig's version, the flags,
and the settings that change what rig emits). Each run still runs and
checks every cell; only a build that would produce the same executable
is skipped."""
import functools, hashlib, os, subprocess


@functools.lru_cache(maxsize=None)
def zig_version(zig):
    return subprocess.run([zig, "version"], capture_output=True, text=True).stdout.strip()


def settings():
    """The RIG_ settings that change what rig emits or how a program runs."""
    where = {"RIG_OUT_DIR", "RIG_BUILD_STORE", "RIG_RESULTS_CACHE", "RIG_RUN_STARTED", "RIG_PROGRAM_STARTED", "RIG_CACHE_MAX_GB"}
    return sorted(f"{k}={v}" for k, v in os.environ.items() if k.startswith("RIG_") and k not in where)


def key(parts):
    h = hashlib.sha256()
    for p in parts:
        b = p if isinstance(p, bytes) else str(p).encode()
        h.update(b"%d:" % len(b) + b)
    return h.hexdigest()


def fresh(exe, parts):
    """Whether `exe` was built from exactly these inputs."""
    stamp = exe + ".inputs"
    try:
        return os.path.exists(exe) and open(stamp).read() == key(parts)
    except OSError:
        return False


def record(exe, parts):
    with open(exe + ".inputs", "w") as f:
        f.write(key(parts))


def file(path):
    with open(path, "rb") as f:
        return f.read()
