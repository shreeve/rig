#!/bin/bash
# run_all.sh <jobs>: build every program list and sweep it (run from the repo root)
set -e
J=${1:-8}
ROOT=$(pwd); W=$ROOT/study/work; rm -rf "$W"; mkdir -p "$W"
git ls-files 'test/*.rig' 'examples/*.rig' 'std/*.rig' | awk '{print $0"\t"$0}' > "$W/tree.tsv"
bash study/extract_docs.sh "$ROOT" "$W/doc" > "$W/docs.raw"
awk -F'\t' '{print $1"\t"$2"/main.rig"}' "$W/docs.raw" > "$W/docs.tsv"
for d in "$W"/doc/*/L*; do echo "$d $(cat $d/mode)"; done > "$W/docs.modes"
find study/probes -name '*.rig' | sort | awk '{print $0"\t"$0}' > "$W/probes.tsv"
python3 study/gen_matrix.py test/matrix.py "$W/matrix" > "$W/matrix.gen.log" 2>&1
awk -F'\t' '{print "matrix/"$1"\t"$2}' "$W/matrix/cells.tsv" > "$W/matrix.tsv"
if [ -f study/hdr/matrix.py ]; then
  python3 study/gen_matrix.py study/hdr/matrix.py "$W/hdr" -k hdr. --rig "$ROOT/bin/rig" > "$W/hdr.gen.log" 2>&1
  awk -F'\t' '{print "hdr/"$1"\t"$2}' "$W/hdr/cells.tsv" > "$W/hdr.tsv"
fi
cat "$W"/tree.tsv "$W"/docs.tsv "$W"/probes.tsv "$W"/matrix.tsv $( [ -f "$W/hdr.tsv" ] && echo "$W/hdr.tsv") > "$W/all.tsv"
wc -l "$W"/*.tsv
python3 study/sweep.py "$ROOT/bin/rig" "$W/all.tsv" "$W/results.jsonl" "$J"
wc -l "$W/results.jsonl"
