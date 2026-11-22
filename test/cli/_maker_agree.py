"""The datetime makers' guard's two steps (test/cli/maker_agree.sh).

    _maker_agree.py gen DIR       write DIR/run.rig, DIR/tuples, DIR/calls
    _maker_agree.py judge DIR     run `rig check` ($RIG) on the constant calls
                                  and compare with DIR/std.out (run.rig's output)

`gen` lists, for each constant-checked maker (`sema.ConstMaker`, but
`TimeZone.named`), the values at and just past each edge of each part,
with the other parts valid, and the cross-part rules. `judge` makes
every tuple as a constant call, one to a line, so `rig check` accepts or
refuses each by line. `run.rig` makes each from arguments the compiler
cannot know, so std's own check runs as the program does, and prints
`ok` or `fail`. `judge` fails on any tuple the two judge differently,
and on a run that judged too few to mean anything.
"""
import sys, os

I64 = 2**63 - 1
# The range of instants, from std/datetime/instant.rig's documentation
# (-9999-01-01T00:00:00 to 9999-12-31T23:59:59.999999999, UTC), computed
# here from the calendar, apart from sema.zig's constants.
def days_from_civil(y, m, d):
    y -= m <= 2
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468

MIN_S = days_from_civil(-9999, 1, 1) * 86400
MAX_S = days_from_civil(9999, 12, 31) * 86400 + 86399
MIN_NS = MIN_S * 10**9
MAX_NS = MAX_S * 10**9 + 999_999_999

YEARS = [-10000, -9999, -9998, -401, -400, -101, -100, -5, -4, -1, 0, 1, 4, 100, 399,
         400, 1899, 1900, 1999, 2000, 2023, 2024, 9998, 9999, 10000]
LEAPS = [-10000, -400, -100, 0, 1900, 2000, 2023, 2024, 9999, 10000]
MONTHS = range(0, 14)
DAYS = [0, 1, 27, 28, 29, 30, 31, 32]
HMS = [-1, 0, 1, 22, 23, 24]
MS = [-1, 0, 1, 58, 59, 60]
NS = [-1, 0, 1, 999_999_999, 1_000_000_000]
SEC_EDGES = [-I64, -I64 + 1, -1, 0, 1, I64 - 1, I64]
NSS = [-1_000_000_000, -999_999_999, -1, 0, 1, 999_999_999, 1_000_000_000]

def date_tuples():
    return [(y, m, d) for y in YEARS for m in MONTHS for d in DAYS]

def tuples():
    t = {}
    t["date"] = date_tuples()
    t["time"] = [(h, 0, 0, 0) for h in HMS] + [(0, m, 0, 0) for m in MS] + [(0, 0, s, 0) for s in MS] + [(0, 0, 0, n) for n in NS]
    t["time"] += [(h, m, s, n) for h in (0, 23, 24) for m in (0, 59, 60) for s in (0, 59, 60) for n in (0, 999_999_999, 1_000_000_000)]
    dt = [(y, m, d, 0, 0, 0, 0) for y in LEAPS for m in (0, 1, 2, 4, 12, 13) for d in (0, 1, 28, 29, 30, 31, 32)]
    dt += [(2024, 1, 1, h, 0, 0, 0) for h in HMS] + [(2024, 1, 1, 0, m, 0, 0) for m in MS]
    dt += [(2024, 1, 1, 0, 0, s, 0) for s in MS] + [(2024, 1, 1, 0, 0, 0, n) for n in NS]
    dt += [(2024, 1, 1, h, m, s, n) for h in (0, 23, 24) for m in (0, 59, 60) for s in (0, 59, 60) for n in (0, 999_999_999, 1_000_000_000)]
    dt += [(2023, 2, 28, 24, 0, 0, 0), (2023, 2, 29, 0, 0, 0, 0), (2023, 2, 29, 24, 0, 0, 0)]
    t["date_time"] = dt
    t["duration_parts"] = [(s, n) for s in [-I64 - 1] + SEC_EDGES for n in NSS]
    ss = [MIN_S - 1, MIN_S, MIN_S + 1, -1, 0, 1, MAX_S - 1, MAX_S, MAX_S + 1, -I64, I64]
    t["unix_s"] = [(s, n) for s in ss for n in NSS]
    def around(unit, lo, hi):
        e = []
        for base in (lo, hi):
            q, r = divmod(base, unit)
            e += [x for x in (q - 1, q, q + 1)]
        return e + [-1, 0, 1]
    t["unix_ms"] = [(x,) for x in around(10**6, MIN_NS, MAX_NS)]
    t["unix_us"] = [(x,) for x in around(10**3, MIN_NS, MAX_NS)]
    t["zone_fixed"] = [(h, m) for h in [-27, -26, -25, -24, -1, 0, 1, 24, 25, 26, 27]
                       for m in [-1561, -1560, -1559, -1500, -60, -59, -1, 0, 1, 59, 60, 1499, 1500, 1559, 1560, 1561]]
    return t

def lit(n):
    # A literal; the least Int has no positive form.
    return str(n)

def const_call(maker, v):
    L = lambda i: lit(v[i])
    if maker == "date":
        return f"datetime.Date.new({L(0)}, {L(1)}, {L(2)})"
    if maker == "time":
        return f"datetime.Time.new({L(0)}, {L(1)}, {L(2)}, ns: {L(3)})"
    if maker == "date_time":
        return f"datetime.DateTime.new({L(0)}, {L(1)}, {L(2)}, hour: {L(3)}, minute: {L(4)}, second: {L(5)}, ns: {L(6)})"
    if maker == "duration_parts":
        return f"time.Duration.from_parts({L(0)}, {L(1)})"
    if maker == "unix_s":
        return f"datetime.Instant.from_unix_s({L(0)}, ns: {L(1)})"
    if maker == "unix_ms":
        return f"datetime.Instant.from_unix_ms({L(0)})"
    if maker == "unix_us":
        return f"datetime.Instant.from_unix_us({L(0)})"
    if maker == "zone_fixed":
        return f"datetime.TimeZone.fixed(hours: {L(0)}, minutes: {L(1)})"

def run_call(maker, v):
    # Arguments through a function's parameters, which are never constants.
    return f"mk_{maker}({', '.join(lit(x) for x in v)})"

PARAMS = {"date": 3, "time": 4, "date_time": 7, "duration_parts": 2, "unix_s": 2,
          "unix_ms": 1, "unix_us": 1, "zone_fixed": 2}

def gen(d):
    t = tuples()
    with open(f"{d}/run.rig", "w") as r, open(f"{d}/tuples", "w") as tf, open(f"{d}/calls", "w") as cf:
        r.write("use std.datetime\nuse std.time\n\n")
        for m, n in PARAMS.items():
            ps = ", ".join(f"p{i}: Int" for i in range(n))
            body = const_call(m, {i: f"p{i}" for i in range(n)})
            r.write(f"fun mk_{m}({ps}) -> Bool\n  _ = {body} catch return false\n  true\n\n")
        r.write("sub main()\n")
        for m in PARAMS:
            for v in t[m]:
                r.write(f"  print({run_call(m, v)})\n")
                cf.write(const_call(m, v) + "\n")
                tf.write(f"{m}{list(v)}\n")

def judge(d):
    import subprocess
    tuples_ = open(f"{d}/tuples").read().splitlines()
    calls = open(f"{d}/calls").read().splitlines()
    std = open(f"{d}/std.out").read().split()
    if len(std) != len(tuples_):
        print(f"FAIL: std judged {len(std)} tuples, {len(tuples_)} were made"); return 1
    # `rig check` shows at most 100 errors, so a file holds at most 95
    # calls std refuses, and at most 50 it makes: a call the compiler
    # judges the other way cannot pass the limit and go unseen.
    verdict = {}
    for want, size in ((False, 95), (True, 50)):
        idx = [i for i, s in enumerate(std) if (s == "true") == want]
        for k in range(0, len(idx), size):
            chunk = idx[k:k + size]
            f = f"{d}/c{int(want)}_{k}.rig"
            with open(f, "w") as o:
                o.write("use std.datetime\nuse std.time\n\nsub main()\n")
                for i in chunk:
                    o.write(f"  _ = {calls[i]}\n")
            out = subprocess.run([os.environ["RIG"], "check", f], capture_output=True, text=True)
            text = out.stdout + out.stderr
            if "more errors not shown" in text:
                print(f"FAIL: {f}: the errors passed the limit"); return 1
            # Every error must be the constant rule's refusal, and the exit
            # status must agree with the errors: a crash, or an error of
            # another kind, fails the guard rather than reading as a verdict.
            errs = set()
            for line in text.splitlines():
                p = line.split(":")
                if len(p) > 3 and p[0].endswith(".rig") and p[1].isdigit() and p[3].strip() == "error":
                    if "always fails" not in line:
                        print(f"FAIL: {f}: an error other than the constant rule's: {line}"); return 1
                    errs.add(int(p[1]))
            if out.returncode != (1 if errs else 0):
                print(f"FAIL: {f}: rig check exited {out.returncode} with {len(errs)} refusals:\n{text}"); return 1
            for j, i in enumerate(chunk):
                verdict[i] = (5 + j) not in errs
    bad = 0
    made = refused = 0
    for i, tup in enumerate(tuples_):
        compiled_ok = verdict[i]
        std_ok = std[i] == "true"
        if compiled_ok != std_ok:
            bad += 1
            print(f"DISAGREE {tup}: rig check {'accepts' if compiled_ok else 'refuses'}, std {'makes it' if std_ok else 'fails'}")
        elif std_ok: made += 1
        else: refused += 1
    makers = {t.split("[")[0] for t in tuples_}
    if bad:
        print(f"FAIL: {bad} of {len(tuples_)} tuples disagree"); return 1
    # Not vacuous: each maker must be seen both made and refused.
    for m in PARAMS:
        v = {std[i] for i, t in enumerate(tuples_) if t.startswith(m + "[")}
        if v != {"true", "false"}:
            print(f"FAIL: {m} was not seen both made and refused"); return 1
    print(f"{len(tuples_)} tuples of {len(makers)} makers agree: {made} made, {refused} refused")
    return 0

if __name__ == "__main__":
    sys.exit(gen(sys.argv[2]) or 0 if sys.argv[1] == "gen" else judge(sys.argv[2]))
