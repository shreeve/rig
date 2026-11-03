B=/zfs/trig-pup/tsrs-shipped/package/tsrs
for proj in empty zod3 ts-pattern; do case $proj in empty) dir=/zfs/trig-cache/fe-proj/empty;; *) dir=/zfs/trig-pup/full/trig/misc/projects/$proj;; esac
cd $dir && env RAYON_NUM_THREADS=1 TSRS_LAZY_DTS=0 python3 /zfs/trig-pup/mem-census/patch/smaps-peak.py /zfs/trig-pup/mem-census/smaps/$proj.go.smaps -- taskset -c 12-19 $B -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers
head -4 /zfs/trig-pup/mem-census/smaps/$proj.go.smaps; done
