#!/bin/bash
# alignpkg.sh SRC DST N [FUNCS]: copy the emitted package SRC to DST with
# align(N) on every function in the program section (each `) linksection(`
# in its Zig), or, with FUNCS (a regex of function names), only on those.
set -euo pipefail
S=$1; D=$2; N=$3; FUNCS=${4:-}
rm -rf "$D"; mkdir -p "$D"
(cd "$S" && find . -name '*.zig' -not -path './.zig-cache/*' | cpio -pdm --quiet "$D")
if [[ -z $FUNCS ]]; then
  find "$D" -name '*.zig' -exec perl -pi -e "s/\\) linksection\\(/) align($N) linksection(/g" {} +
else
  find "$D" -name '*.zig' -exec perl -pi -e "s/(fn ($FUNCS)\\(.*?\\)) linksection\\(/\$1 align($N) linksection(/g" {} +
fi
