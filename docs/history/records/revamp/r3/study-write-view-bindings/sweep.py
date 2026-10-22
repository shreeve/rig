# sweep.py <rig> <list.tsv> <out.jsonl> <jobs>: run `rig emit` with RIG_STUDY=report over each program
import sys, subprocess, json, os, concurrent.futures, re
rig, listing, out, jobs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
items = [l.rstrip('\n').split('\t') for l in open(listing) if l.strip()]
env = dict(os.environ, RIG_STUDY='report')
def one(it):
    ident, path = it[0], it[1]
    try:
        p = subprocess.run([rig, "emit", os.path.abspath(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, timeout=180)
        rc = p.returncode; err = p.stderr.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        rc = -999; err = ''
    rules, probes, errs = [], [], []
    for l in err.splitlines():
        if l.startswith('STUDY '): rules.append(l[6:])
        elif l.startswith('STUDYPROBE '): probes.append(l[11:])
        elif ': error: ' in l and len(errs) < 3: errs.append(re.sub(r'^.*?: error: ', '', l)[:200])
    return {'id': ident, 'path': path, 'rc': rc, 'rules': rules, 'probes': probes, 'errs': errs}
with open(out, 'w') as fh, concurrent.futures.ThreadPoolExecutor(jobs) as ex:
    for r in ex.map(one, items, chunksize=8):
        fh.write(json.dumps(r) + '\n')
