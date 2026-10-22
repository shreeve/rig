#!/bin/bash
# extract_docs.sh <repo> <outdir>: the doc examples, as ./test/run extracts them; prints "id<TAB>dir"
set -e
repo=$1; out=$2; mkdir -p "$out"
eval "$(sed -n '/^extract_docs() {/,/^}/p' "$repo/test/run")"
cd "$repo"
for md in *.md docs/*.md examples/*.md test/*.md; do
    [[ -e "$md" ]] || continue
    extract_docs "$md" "$out"
done
