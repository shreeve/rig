# (b) 10,000 small maps of 4 to 64 entries keyed by pairs of Ints: each
# built in turn, then hits and misses across them all, then dropped.
key pair
ids dense
value 8
instances 10000
size 4-64
mix insert=20 hit=60 miss=20
order build
seed 2
