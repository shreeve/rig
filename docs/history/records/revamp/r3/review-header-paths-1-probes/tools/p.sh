#!/bin/bash
# usage: p.sh file.rig [release]
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
f=$(cd $(dirname $1) && pwd)/$(basename $1)
b=$(basename $f .rig)
nc=$($S/new/bin/rig check $f 2>&1 | grep -m1 -E "error|warning" | cut -c1-220)
oc=$($S/old/bin/rig check $f 2>&1 | grep -m1 -E "error|warning" | cut -c1-160)
no=$($S/new/bin/rig-oracle -v $f 2>&1 | grep -E "DIFF|ref=reject|prod=reject" | sed 's/^[^ ]* //' | cut -c1-200 | head -3)
oo=$($S/old/bin/rig-oracle -v $f 2>&1 | grep -E "DIFF|ref=reject|prod=reject" | sed 's/^[^ ]* //' | cut -c1-200 | head -3)
echo "=== $b"
echo "  new: ${nc:-ACCEPT}"
echo "  old: ${oc:-ACCEPT}"
[ -n "$no" ] && echo "$no" | sed 's/^/  oracle-new: /'
[ -n "$oo" ] && echo "$oo" | sed 's/^/  oracle-old: /'
if [ -z "$nc" ]; then
  out=$(cd $S/hp1 && RIG_SANITIZE=1 timeout 60 $S/new/bin/rig run $f 2>&1 | tail -4 | cut -c1-200)
  echo "  run: $(echo "$out" | tr '\n' '|')"
  if [ "$2" = release ]; then
    (cd $S/hp1 && timeout 120 $S/new/bin/rig build --release -o $S/hp1/rel_$b $f >/dev/null 2>&1 && out=$(timeout 30 $S/hp1/rel_$b 2>&1 | tail -4 | cut -c1-200); echo "  rel: $(echo "$out" | tr '\n' '|')"; rm -f $S/hp1/rel_$b)
  fi
fi
