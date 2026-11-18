#!/bin/bash
# job.sh ROW: one board row, run inside a mac-claim. Arms m10, m11, aa11, plus Tokio or hyper.
B=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/fb
cd $B; A=$B/arms; R=$B/raw
./state.sh
case $1 in
net)    python3 netboard.py ${ROUNDS:-15} $R/net.jsonl m10=$A/m10-net m11=$A/m11-net aa11=$A/aa11-net tokio=$A/tokio-net ;;
tasks2) python3 netboard.py ${ROUNDS:-30} $R/tasks2.jsonl m10=$A/m10-tasks m11=$A/m11-tasks aa11=$A/aa11-tasks tokio=$A/tokio-tasks ;;
closed) python3 closed.py ${ROUNDS:-7} $R/closed.jsonl m10=$A/m10-http m11=$A/m11-http aa11=$A/aa11-http hyper=$A/hyper-http ;;
mix)    PACES=sleep MIX=4 IDLE=5000 RIG_WORKERS=8 TOKIO_WORKER_THREADS=8 HYPER_WORKERS=8 \
          python3 run2.py ${ROUNDS:-10} $R/mix2.jsonl 100000 m10=$A/m10-mixed m11=$A/m11-mixed aa11=$A/aa11-mixed hyper=$A/hyper-mixed ;;
esac
rc=$?
./state.sh
exit $rc
