# (a) One large map of u32 ids grown to 200,000 keys, 8-byte values;
# inserts, hits, misses and walks interleaved in segments of 256.
key u32
ids dense
value 8
instances 1
size 200000
mix insert=25 hit=50 miss=20 iterate=5
order interleaved
seed 1
