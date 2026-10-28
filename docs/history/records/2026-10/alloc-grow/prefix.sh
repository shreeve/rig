# The rows map.zig runs before the bigs rows, in its order.
P=""
for s in 16 1000 100000 4000000; do P="$P sized:$s"; done
for s in 16 24 1000 1500 100000 150000 3000000 4000000; do P="$P random:$s"; done
for f in latency churn mixed; do for s in 16 1000 100000 4000000; do P="$P $f:$s"; done; done
for s in 16 1000 100000 1000000; do P="$P texts:$s"; done
echo $P
