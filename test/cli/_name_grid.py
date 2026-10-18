#!/usr/bin/env python3
"""Every name a Rig program may choose keeps its meaning in the emitted
Zig: a name Zig reserves (`var`, `fn`, `u8`, `null`), a name the
emitter or Zig's standard library uses (`std`, `rig`, `panic`, `debug`,
`os`, `std_options`, `__rig_x`), and `_`, at every place a name stands.

  test/cli/_name_grid.py <rig> [--jobs N] [--keep DIR] [SITE...]
  test/cli/_name_grid.py --cases FILE

Each site is a block for every name, and the sites are built as a few
programs (GROUPS): its locals, parameters, captures, and bindings; an owned local
whose drop a flag guards, beside a later local named like it; methods, and the
locals and parameters beside a method of the same name; fields and
payload fields; variants; errors and labels; generic parameters; type
names; module constants and functions; static methods; module members;
modules and `use ... as` aliases. The program must pass `rig check`,
run sanitizer-clean, and print, for each name, what the name's block
says. Prints each failure and exits 1 if any. A program's root module is
Zig's root, where Zig's standard library looks up its hooks, so it is
built with `rig run` and not in a test file's pack.

A name the site rejects is listed in REJECTED with the diagnostic `rig
check` must give it. `--cases FILE` writes each as a `fail` case of a
program of its own to FILE, test/rig/names-name-grid.rig.test, which
test/cli/name_grid.sh keeps equal to what this writes.
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys, tempfile

# Names Zig reserves: its keywords and its primitive types and values.
ZIG = """addrspace align allowzero anyframe anytype asm callconv comptime export
fn inline linksection noalias noinline nosuspend opaque orelse packed resume
struct suspend switch threadlocal union unreachable usingnamespace var volatile
null undefined u8 i64 u0 i7 u65535 bool void type noreturn anyerror anyopaque
f16 f32 f64 f80 f128 usize isize c_int c_char c_long comptime_int
comptime_float""".split()
# Names the emitted Zig or Zig's standard library uses: the prelude's
# imports and panic handler, the emitter's own names, and the hooks
# Zig's standard library looks up in the root module.
EMITTER = """std rig panic __rig __rig_x __rig_tmp_1 __rig_Self __rig_module debug
os tracy main std_options std_options_debug_io std_options_cwd _start
__start WinMain wWinMain WinMainCRTStartup wWinMainCRTStartup DllMain
DllMainCRTStartup _DllMainCRTStartup EfiMain""".split()
# Names with a meaning of their own in Rig or the runtime, `_`, and a
# plain name to compare with.
RIG = "self Self none some from_int drop new len get it value init clone _ x0".split()
NAMES = ZIG + EMITTER + RIG

# Which sites reject a name, and a part of the diagnostic `rig check`
# gives it.
NONE = "`none` is the absent optional"
UNDERSCORE = "`_` discards a value"
# Every program here declares `sub main()`, which no other name hides.
MAIN = "module-level declaration `main`"
DUPLICATE = "duplicate declaration of `main`"
# Rig's own keywords (`type`, `drop`, `panic`) name nothing but a member
# (SYNTAX.md, "Keywords"); any diagnostic will do.
KEYWORD = "error:"
BINDING = {"none": NONE, "_": UNDERSCORE, "type": KEYWORD, "drop": KEYWORD, "panic": KEYWORD, "main": MAIN}
REJECTED = {
    "local": {**BINDING},
    "flag": {**BINDING},
    "method": {**BINDING, "self": "self"},
    "field": {},
    "variant": {"none": "none", "from_int": "from_int", "type": KEYWORD, "drop": KEYWORD, "panic": KEYWORD},
    "error": {"none": "none", "type": KEYWORD, "drop": KEYWORD, "panic": KEYWORD},
    "tparam": {**BINDING, "_": None, "self": "self", "Self": "built-in type"},
    "type": {**BINDING, "self": "self", "new": "new", "main": DUPLICATE},
    "root_const": {**BINDING, "main": DUPLICATE},
    "root_fun": {**BINDING, "main": DUPLICATE},
    "static": {"from_int": "from_int"},
    # A module-level `self` is hidden by every method's receiver.
    "module": {**BINDING, "_": None, "from_int": "from_int", "self": "module-level declaration `self`", "main": "cyclic import",
               **{n: "reserved for the compiler" for n in NAMES if n.startswith("__rig")}},
    "alias": {**BINDING, "_": None, "main": "`main` is a declaration of this module"},
}


def local(n, i):
    return f"""error LE{i}
  bad

fun lfail{i}() -> Int!
  return LE{i}.bad

enum LP{i}
  pp(v: Int)
  qq

fun lp{i}({n}: Int) -> Int
  {n} + 1

fun lf{i}() -> Int
  s = 0
  for {n} in 0..3
    s += {n}
  s

fun lo{i}(o: Int?) -> Int
  if o as {n}
    return {n}
  0

fun lc{i}() -> Int
  {n} = 41
  g = |+{n}| {n} + 1
  g()

fun lm{i}(p: LP{i}) -> Int
  match p
    .pp(v: {n}) => {n}
    .qq => 0

sub lb{i}({n}: !Int)
  {n} += 1

sub t{i}()
  x = lfail{i}() catch |{n}|
    print({n})
    7
  k = 1
  lb{i}(!k)
  print(lp{i}(41), lf{i}(), lo{i}(5), lc{i}(), x, lm{i}(.pp(v: 9)), k)
""", f"LE{i}.bad\n42 3 5 42 7 9 2"


def flag(n, i):
    """An owned local whose drop a flag guards, and a later local named
    like the names the emitter makes from it."""
    return f"""fun take{i}(s: String) -> Int
  s.len

fun fl{i}(c: Bool) -> Int
  {n} = String("ab")
  k = 0
  if c
    k += take{i}(<{n})
  {n}_2 = String("cde")
  if not c
    k += take{i}(<{n}_2)
  k

sub t{i}()
  print(fl{i}(true), fl{i}(false))
""", "2 3"


def method(n, i):
    return f"""obj M{i}
  v: Int

  fun {n}(?self) -> Int
    self.v

  fun b(?self) -> Int
    {n} = self.v + 1
    {n} + self.{n}()

  fun c(?self, {n}: Int) -> Int
    {n} + self.{n}()

  fun d(?self) -> Int
    g = |?self|
      {n} = self.v + 2
      {n}
    g()

  sub {n}2(!self)
    self.v += 1

obj GM{i}[T]
  v: T

  fun {n}(?self) -> Int
    1

  fun b(?self, {n}: Int) -> Int
    {n} + self.{n}()

sub t{i}()
  m = M{i}(v: 1)
  !m.{n}2()
  h = |?m| m.{n}()
  print(m.{n}(), m.b(), m.c(10), m.d(), h(), GM{i}[Int](v: 0).b(5))
""", "2 5 12 4 2 6"


def field(n, i):
    return f"""obj O{i}
  {n}: Int = 5
  b: Int

obj G{i}[T]
  {n}: T

enum P{i}
  pp({n}: Int, b: Int)
  qq

enum Q{i}
  ss({n}: String)

obj W{i}
  {n}: String

  drop(!self)
    print("drop", self.{n})

fun pv{i}(p: P{i}) -> Int
  match p
    .pp({n}: x, b: y) => x + y
    .qq => 0

fun mk{i}(x: Int = 3) -> O{i}
  O{i}({n}: x, b: 1)

sub t{i}()
  o = O{i}(b: 1)
  o.{n} += 1
  g = G{i}[Int]({n}: 9)
  print(o.{n}, g.{n}, pv{i}(P{i}.pp({n}: 1, b: 2)), pv{i}(.pp(b: 3, {n}: 4)), mk{i}().{n})
  print(O{i}({n}: 7, b: 2), P{i}.pp({n}: 1, b: 2), O{i}({n}: 1, b: 2) == O{i}({n}: 1, b: 2))
  print(String(o))
  w = W{i}({n}: String("hi"))
  s = replace(!w.{n}, String("yo"))
  c = +w.{n}
  q = Q{i}.ss({n}: String("x"))
  r = +q
  print(s, c, r)
""", f"6 9 3 7 3\nO{i}({n}: 7, b: 2) .pp({n}: 1, b: 2) true\nO{i}({n}: 6, b: 1)\nhi yo .ss({n}: \"x\")\ndrop yo"


def variant(n, i):
    return f"""enum K{i}
  zz
  {n}

enum V{i}
  aa = 3
  {n} = 7

enum P{i}
  pp(v: Int)
  {n}(w: Int)

enum G{i}[T]
  gg(v: T)
  {n}(w: T)

obj B{i}
  k: K{i} = .{n}
  v: V{i} = .{n}

fun pick{i}(k: K{i} = .{n}) -> Int
  Int(k)

fun pv{i}(p: P{i}) -> Int
  match p
    .{n}(w: x) => x
    .pp(v) => v

fun gv{i}(g: G{i}[Int]) -> Int
  match g
    .{n}(w) => w
    _ => 0

sub t{i}()
  b = B{i}()
  k: K{i} = .{n}
  print(Int(b.k), Int(b.v), pick{i}(), pick{i}(.zz), k == .{n}, k == K{i}.{n}, b.v == .{n})
  match k
    .{n} => print("m1")
    .zz => print("m0")
  print(Int(V{i}.from_int(7) ?? V{i}.aa), pv{i}(P{i}.{n}(w: 5)), pv{i}(.pp(v: 6)), gv{i}(G{i}[Int].{n}(w: 8)))
  n = 0
  for x in @variants(V{i})
    n += Int(x)
  print(n, K{i}.{n}, V{i}.{n}, P{i}.{n}(w: 1), String(k))
  for x in @variants(K{i})
    print(x)
""", f"1 7 1 0 true true true\nm1\n7 5 6 8\n10 .{n} .{n} .{n}(w: 1) .{n}\n.zz\n.{n}"


def error(n, i):
    return f"""error E{i}
  zz
  {n}

fun f{i}(k: Int) -> Int!
  if k == 1
    return E{i}.{n}
  if k == 2
    return E{i}.zz
  k

sub t{i}()
  t = 0
  @{n} for a in 0..3
    for j in 0..3
      if j == 2
        continue @{n}
      if a == 2
        break @{n}
      t += 1
  print(t)
  _ = f{i}(1) catch |e|
    print(e, e == E{i}.{n}, e == E{i}.zz)
    0
  c = f{i}(1) catch |e|
    match e
      E{i}.{n} => 7
      _ => 8
  print(c)
""", f"4\nE{i}.{n} true false\n7"


def tparam(n, i):
    return f"""obj GT{i}[{n}]
  x: {n}

  fun first(?self) -> {n}
    self.x

enum HT{i}[{n}]
  one(v: {n})
  two

fun id{i}[{n}](x: {n}) -> {n}
  x

fun sz{i}[{n}]() -> Int
  @size({n})

sub t{i}()
  g = GT{i}[Int](x: 4)
  h = HT{i}[Int].one(v: 7)
  match h
    .one(v) => print(v)
    .two => print("two")
  print(g.first(), id{i}[Int](5), id{i}(6), sz{i}[U8](), g, @name(GT{i}[Int]))
""", f"7\n4 5 6 1 GT{i}(x: 4) GT{i}[Int]"


def type_(n, i):
    return f"""obj {n}
  v: Int

  fun get2(?self) -> Int
    self.v

enum {n}E
  a
  b

error {n}Err
  bad

fun mk{i}(v: Int) -> {n}
  {n}(v: v)

fun fails{i}() -> Int!
  return {n}Err.bad

sub t{i}()
  o = {n}(v: 3)
  print(o.get2(), o, @name({n}), mk{i}(2).v, {n}E.b)
  x = fails{i}() catch |e|
    print(e)
    0
  print(x)
""", f"3 {n}(v: 3) {n} 2 .b\n{n}Err.bad\n0"


def root_const(n, i):
    return f"""{n} = 10
{n}s = [{n}, 2]

obj RC{i}
  v: Int = {n}

fun rc{i}(x: Int = {n}) -> Int
  x + {n}

sub t{i}()
  print({n}, {n}s, RC{i}().v, rc{i}())
""", "10 [10, 2] 10 20"


def root_fun(n, i):
    return f"""fun {n}(x: Int) -> Int
  x * 2

sub t{i}()
  f = {n}
  print({n}(4), f(5))
""", "8 10"


def static(n, i):
    return f"""obj PS{i}
  x: Int

fun PS{i}.{n}() -> PS{i}
  PS{i}(x: 4)

sub PS{i}.{n}2(!self)
  self.x += 1

enum KS{i}
  a
  b

  fun {n}(?self) -> Int
    Int(self) + 7

fun KS{i}.{n}3() -> KS{i}
  .b

sub t{i}()
  p = PS{i}.{n}()
  !p.{n}2()
  print(p.x, KS{i}.a.{n}(), Int(KS{i}.{n}3()))
""", "5 7 1"


def module_lib(n, i):
    return f"""pub enum K{i}
  zz
  {n}

pub enum P{i}
  pp(v: Int)
  {n}(w: Int)

pub enum G{i}[T]
  gg(v: T)
  {n}(w: T)

pub obj Box{i}
  pub k: K{i} = .{n}
  pub {n}: Int = 4

  pub fun {n}2(?self) -> Int
    self.{n} + 1

pub error E{i}
  zz
  {n}

pub fun pick{i}(k: K{i} = .{n}) -> Int
  Int(k)

pub fun fails{i}(k: Int) -> Int!
  if k == 0
    return E{i}.{n}
  k

pub fun {n}(x: Int) -> Int
  x + 100
"""


def module(n, i):
    """A module named `n` (`use n`), and members named `n` of another."""
    return f"""fun pv{i}(p: lib.P{i}) -> Int
  match p
    .{n}(w) => w
    .pp(v) => v

fun gv{i}(g: lib.G{i}[Int]) -> Int
  match g
    .{n}(w: x) => x
    _ => 0

sub t{i}()
  b = lib.Box{i}()
  print(Int(b.k), b.{n}, b.{n}2(), lib.pick{i}(), lib.pick{i}(.zz), lib.{n}(1), {n}.two())
  k: lib.K{i} = .{n}
  print(k == lib.K{i}.{n}, k == .{n})
  match k
    .{n} => print("m")
    .zz => print("z")
  print(pv{i}(lib.P{i}.{n}(w: 5)), gv{i}(lib.G{i}[Int].{n}(w: 6)))
  x = lib.fails{i}(0) catch |e|
    print(e == lib.E{i}.{n}, e)
    -1
  print(x, lib.Box{i}({n}: 9).{n})
""", f"1 4 5 1 0 101 2\ntrue true\nm\n5 6\ntrue E{i}.{n}\n-1 9"


def alias(n, i):
    return f"""sub t{i}()
  print({n}.two(), {n}.Box().v)
""", "2 4"


SITES = {
    "local": local, "flag": flag, "method": method, "field": field, "variant": variant,
    "error": error, "tparam": tparam, "type": type_, "root_const": root_const,
    "root_fun": root_fun, "static": static, "module": module, "alias": alias,
}


# The programs a run builds: the sites whose names stand inside a
# declaration share one, each block numbered apart; a site that declares
# its names at the module's top, or imports them, has one of its own.
GROUPS = [["local", "flag", "method", "field", "variant", "error", "tparam", "static"],
          ["type"], ["root_const"], ["root_fun"], ["module"], ["alias"]]
assert sorted(s for g in GROUPS for s in g) == sorted(SITES)


def program(sites, names):
    """The files of one program holding each site's blocks for its names
    (`names[site]`): {path: source}, the expected output, and the line
    range of each block in main.rig, with its site and name. The `j`th
    name of the `k`th site has block number 1000 * k + j."""
    files, parts, want, spans, calls, line = {}, [], [], [], [], 1
    head = ""
    for k, site in enumerate(sites):
        ns = names[site]
        if site == "module":
            head += "use lib\n" + "".join(f"use {n}\n" for n in ns) + "\n"
            files["lib.rig"] = "\n".join(module_lib(n, 1000 * k + j) for j, n in enumerate(ns))
            for n in ns:
                files[f"{n}.rig"] = "pub fun two() -> Int\n  2\n"
        elif site == "alias":
            head += "".join(f"use small as {n}\n" for n in ns) + "\n"
            files["small.rig"] = "pub fun two() -> Int\n  2\n\npub obj Box\n  pub v: Int = 4\n"
    line += head.count("\n")
    for k, site in enumerate(sites):
        for j, n in enumerate(names[site]):
            i = 1000 * k + j
            src, out = SITES[site](n, i)
            spans.append((line, line + src.count("\n"), f"{site} {n}"))
            line += src.count("\n") + 1
            parts.append(src)
            want.append(out)
            calls.append(f"  t{i}()\n")
    files["main.rig"] = head + "\n".join(parts) + "\n" + "sub main()\n" + "".join(calls)
    return files, "\n".join(want), spans


def write(work, files):
    os.makedirs(work, exist_ok=True)
    for name, src in files.items():
        with open(os.path.join(work, name), "w") as f:
            f.write(src)
    return os.path.join(work, "main.rig")


def rig(rig_bin, cmd, path, out):
    env = dict(os.environ, RIG_OUT_DIR=out, RIG_SANITIZE="1")
    return subprocess.run([rig_bin, cmd, path], capture_output=True, text=True, env=env, timeout=900)


def blame(text, spans):
    """The names whose blocks the diagnostics in `text` point into."""
    hit = set()
    for m in re.finditer(r"main\.rig:(\d+):\d+: error", text):
        ln = int(m.group(1))
        hit.update(n for lo, hi, n in spans if lo <= ln <= hi)
    return sorted(hit)


def rejected_of(site):
    return {n: why for n, why in REJECTED.get(site, {}).items() if why is not None}


def check_group(rig_bin, work, sites):
    names = {site: [n for n in NAMES if n not in rejected_of(site)] for site in sites}
    files, want, spans = program(sites, names)
    label = "+".join(sites)
    d = os.path.join(work, sites[0])
    path = write(d, files)
    bad = []
    # `rig run` checks the program first; a rejection names the blocks
    # its diagnostics point into.
    r = rig(rig_bin, "run", path, os.path.join(d, "out"))
    got = r.stdout.rstrip("\n")
    blamed = blame(r.stderr, spans)
    if r.returncode and blamed:
        bad.append(f"{label}: rejected, names {blamed}\n  " + r.stderr[:2000])
    elif r.returncode or got != want:
        g, w = got.split("\n"), want.split("\n")
        diff = next((k for k in range(max(len(g), len(w))) if k >= len(g) or k >= len(w) or g[k] != w[k]), None)
        where = f" first difference at output line {diff + 1}: got {g[diff] if diff is not None and diff < len(g) else None!r}, want {w[diff] if diff is not None and diff < len(w) else None!r}" if diff is not None else ""
        bad.append(f"{label}: exit {r.returncode}{where}\n  " + r.stderr[-2000:])
    return bad, sum(len(ns) for ns in names.values())


def cases():
    """The test file of the rejected names: a `fail` case for each, its
    program's other files after it."""
    out = ["# names: each name a place where a name stands rejects, with the",
           "# diagnostic it gives. Written by test/cli/_name_grid.py --cases;",
           "# test/cli/name_grid.sh checks it is what that writes. A keyword of",
           "# Rig's own may draw any diagnostic, \"\".", ""]
    for site in SITES:
        for n, why in rejected_of(site).items():
            files, _, _ = program([site], {site: [n]})
            out.append(f'fail "name grid {site} {n}", "{"" if why == KEYWORD else why}"')
            for name in ["main.rig"] + sorted(f for f in files if f != "main.rig"):
                if name != "main.rig":
                    out.append(f'  file "{name}"')
                for line in files[name].rstrip("\n").split("\n"):
                    pad = "  " if name == "main.rig" else "    "
                    out.append(pad + line if line else "")
            out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig", nargs="?")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--keep", help="write the programs here and keep them")
    ap.add_argument("--cases", help="write the rejected names' cases to this file")
    ap.add_argument("sites", nargs="*")
    a = ap.parse_args()
    if a.cases:
        with open(a.cases, "w") as f:
            f.write(cases())
        return
    if not a.rig:
        ap.error("the rig to check is missing")
    groups = [[s for s in g if not a.sites or s in a.sites] for g in GROUPS]
    groups = [g for g in groups if g]
    work = a.keep or tempfile.mkdtemp(prefix="name_grid_")
    if a.keep:
        shutil.rmtree(work, ignore_errors=True)
    try:
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            results = list(ex.map(lambda g: check_group(a.rig, work, g), groups))
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)
    bad = [line for res, _ in results for line in res]
    for line in bad:
        print(line)
    accepted = sum(n for _, n in results)
    print(f"{sum(map(len, groups))} sites in {len(groups)} programs, {len(NAMES)} names: {accepted} run, {len(bad)} bad")
    sys.exit(1 if bad else 0)


main()
