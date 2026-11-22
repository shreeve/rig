#!/bin/bash
cd "$(dirname "$0")"
for o in asc mix desc; do for m in b16 b8; do for i in 1 2; do echo -n "$m $o: "; ORDER=$o ./floor3 $m 10 21 2>&1 >/dev/null | tail -1; done; done; done
