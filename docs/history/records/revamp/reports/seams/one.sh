#!/bin/bash
# usage: one.sh BIN file  -> prints "status<TAB>file<TAB>first interesting line"
BIN=$1; f=$2
out=$(cd "$(dirname "$f")" && perl -e 'alarm 60; exec @ARGV' "$BIN" check "$(basename "$f")" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  if echo "$out" | grep -qiE 'internal error|panic|segmentation'; then printf 'ICE_CHECK\t%s\t%s\n' "$f" "$(echo "$out" | grep -iE 'internal|panic|segm' | head -1)"; else printf 'REJECT\t%s\t%s\n' "$f" "$(echo "$out" | head -1)"; fi
  exit 0
fi
out=$(cd "$(dirname "$f")" && perl -e 'alarm 90; exec @ARGV' "$BIN" run "$(basename "$f")" 2>&1 </dev/null); rc=$?
if echo "$out" | grep -qiE 'leak'; then st=LEAK
elif echo "$out" | grep -qiE 'double free|use after|panic|segmentation|reached unreachable|index out of bounds|General protection|Bus error'; then st=PANIC
elif echo "$out" | grep -qE '\.zig:[0-9]+:[0-9]+: error'; then st=ZIGERR
elif echo "$out" | grep -qi 'internal error'; then st=ICE_EMIT
elif [ $rc -eq 142 ] || [ $rc -eq 14 ]; then st=TIMEOUT
elif [ $rc -ne 0 ]; then st="EXIT$rc"
else st=OK; fi
printf '%s\t%s\t%s\n' "$st" "$f" "$(echo "$out" | grep -iE 'leak|panic|free|error|unreachable|bounds' | head -1 | cut -c1-200)"
