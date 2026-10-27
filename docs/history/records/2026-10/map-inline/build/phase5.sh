cd /zfs/worktrees/rig/map-inline
until [ -f res4/DONE ]; do sleep 30; done
sh score-mi3.sh 25 ts-pattern zod3 > res4/score.txt 2>&1
echo done > res4/DONE5
