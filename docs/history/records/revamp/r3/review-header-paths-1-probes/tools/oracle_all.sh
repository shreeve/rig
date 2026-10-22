#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
cd $S/new
find test/reject test/behavior test/known examples test/corpus -name '*.rig' | sort > $S/hp1/oracle_files.txt
cat $S/hp1/oracle_files.txt | xargs -P 2 -n 300 $S/new/bin/rig-oracle -v 2>/dev/null | grep -E " prod=" | sort > $S/hp1/oracle_new.txt
cat $S/hp1/oracle_files.txt | xargs -P 2 -n 300 $S/old/bin/rig-oracle -v 2>/dev/null | grep -E " prod=" | sort > $S/hp1/oracle_old.txt
