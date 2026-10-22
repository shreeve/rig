#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
cd $S/new
cat $S/hp1/recv_files.txt | xargs -P 2 -n 100 $S/new/bin/rig-oracle -v 2>/dev/null | grep -E " prod=" | sed 's/^stricter //; s/^DIFF //' | sort > $S/hp1/oracle_new.txt
cat $S/hp1/recv_files.txt | xargs -P 2 -n 100 $S/old/bin/rig-oracle -v 2>/dev/null | grep -E " prod=" | sed 's/^stricter //; s/^DIFF //' | sort > $S/hp1/oracle_old.txt
cat $S/hp1/recv_files.txt | xargs -P 2 -n 100 $S/hp1x/bin/rig-oracle -v 2>/dev/null | grep -E " prod=" | sed 's/^stricter //; s/^DIFF //' | sort > $S/hp1/oracle_narrow.txt
