#!/usr/bin/env python3
"""Run generated Rig programs and classify outcomes.

A case is a directory <root>/<id>/ holding main.rig (and maybe lib.rig) and
expect.json: {"kind": "out"|"panic"|"reject"|"any", "out": "...", "area": "..."}.
Results go to <root>/results.jsonl.
"""
import json, os, re, subprocess, sys, threading, queue, time, signal

RIG = "/Users/shreeve/Data/Code/rig/bin/rig"
DIAG = re.compile(r"^[^\s:]+\.rig:\d+:\d+: error:", re.M)


def run(cmd, cwd, env, timeout):
    p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out.decode("utf8", "replace"), err.decode("utf8", "replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
        out, err = p.communicate()
        return None, out.decode("utf8", "replace"), err.decode("utf8", "replace"), True


def own_oracle(out):
    live = {}
    for ln, line in enumerate(out.splitlines()):
        p = line.split()
        if len(p) == 2 and p[0] in ("new", "use", "rel"):
            i = p[1]
            if p[0] == "new":
                live[i] = live.get(i, 0) + 1
            elif p[0] == "use":
                if live.get(i, 0) <= 0:
                    return f"line {ln}: use {i} while not live"
            else:
                if live.get(i, 0) <= 0:
                    return f"line {ln}: rel {i} while not live (double release)"
                live[i] -= 1
    left = [i for i, c in live.items() if c]
    if left:
        return "never released: " + " ".join(left)
    return None


def classify(case_dir, outdir, check_only=False):
    exp = json.load(open(os.path.join(case_dir, "expect.json")))
    env = dict(os.environ)
    env["RIG_OUT_DIR"] = outdir
    rc, out, err, to = run([RIG, "check", "main.rig"], case_dir, env, 30)
    res = {"id": os.path.basename(case_dir), "area": exp.get("area", "?"), "kind": exp["kind"]}
    if to:
        res.update(outcome="CHECK_HANG")
        return res
    if rc != 0:
        crashed = rc < 0 or "panic" in err or "internal error" in err or "Segmentation" in err \
            or "unreachable" in err.lower() and "reached unreachable" in err
        if crashed:
            res.update(outcome="CHECK_CRASH", err=err[-3000:])
        elif DIAG.search(err):
            res.update(outcome="rejected" if exp["kind"] == "reject" else "rejected_unexpected", err=err[:1500])
        else:
            res.update(outcome="CHECK_NO_POS", err=err[-2000:])
        return res
    if exp["kind"] == "reject" and not exp.get("run_anyway"):
        res.update(outcome="ACCEPTED_SHOULD_REJECT")
        # still run to see what happens
    if check_only:
        res.update(outcome="checked")
        return res
    rc, out, err, to = run([RIG, "run", "main.rig"], case_dir, env, 40 if exp["kind"] == "anyrun" else 180)
    res["stdout"] = out[-3000:]
    res["stderr"] = err[-3000:]
    if to:
        res["outcome"] = "RUN_HANG"
        return res
    if "internal error" in err:
        res["outcome"] = "INTERNAL_ERROR"
    elif re.search(r"\.zig:\d+:\d+: error:", err) or "error: the following command" in err \
            or ("error:" in err and "rig/" in err and ".zig" in err and rc != 0 and "panic" not in err):
        res["outcome"] = "ZIG_ERROR"
    elif "memory leak" in err:
        res["outcome"] = "LEAK"
    elif "Double free" in err or "double free" in err or "Invalid free" in err:
        res["outcome"] = "DOUBLE_FREE"
    elif exp["kind"] == "anyrun":
        res["outcome"] = "ok" if rc == 0 else ("anyrun_panic" if "panic" in err else "RUN_FAIL")
    elif exp["kind"] == "panic":
        if rc != 0 and "panic" in err:
            ok = exp.get("panic_text") is None or exp["panic_text"] in err
            res["outcome"] = "ok_panic" if ok else "WRONG_PANIC"
            if exp.get("out") is not None and out != exp["out"]:
                res["outcome"] = "WRONG_OUTPUT"
        else:
            res["outcome"] = "MISSING_PANIC"
    elif rc != 0:
        res["outcome"] = "RUN_PANIC" if "panic" in err else "RUN_FAIL"
    elif exp["kind"] == "reject":
        res["outcome"] = "ACCEPTED_SHOULD_REJECT"
    elif exp["kind"] == "own":
        bad = own_oracle(out)
        res["outcome"] = "ok" if not bad else "WRONG_OUTPUT"
        if bad:
            res["expected"] = bad
    elif exp["kind"] == "any":
        res["outcome"] = "ok" if "FAIL" not in out else "WRONG_OUTPUT"
    elif out == exp["out"]:
        res["outcome"] = "ok"
    else:
        res["outcome"] = "WRONG_OUTPUT"
        res["expected"] = exp["out"][-3000:]
    return res


def main():
    root = sys.argv[1]
    jobs = int(sys.argv[2]) if len(sys.argv) > 2 else 9
    check_only = "--check-only" in sys.argv
    cases = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and
                   os.path.exists(os.path.join(root, d, "expect.json")))
    q = queue.Queue()
    for c in cases:
        q.put(c)
    lock = threading.Lock()
    resf = open(os.path.join(root, "results.jsonl"), "w")
    counts = {}
    done = [0]

    def worker(i):
        outdir = os.path.join(root, f".out{i}")
        while True:
            try:
                c = q.get_nowait()
            except queue.Empty:
                return
            try:
                r = classify(os.path.join(root, c), outdir, check_only)
            except Exception as e:
                r = {"id": c, "outcome": "HARNESS_ERR", "err": repr(e)}
            with lock:
                resf.write(json.dumps(r) + "\n")
                resf.flush()
                counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
                done[0] += 1
                if done[0] % 50 == 0:
                    print(done[0], "/", len(cases), counts, flush=True)

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(jobs)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    print("DONE", counts)


if __name__ == "__main__":
    main()
