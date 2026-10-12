MB/s (fastest of 15 interleaved runs) and the change against `base` in time / in cycles; instructions per byte last
| file | base | utf8_kl+esc_copy16+esc_hex16b | src:wsbits3+wsb_tbl+vread | src:wsbits3+wsb_tbl+utf8_kl+esc_copy16+esc_hex16b+vread | ext:sonic |
|---|---:|---:|---:|---:|---:|
| twitter | 3236 (9.86 i/B) | 3402: 5% faster / 5% faster (9.08 i/B) | 3160: 2% slower / 3% slower (9.46 i/B) | 3364: 4% faster / 4% faster (8.34 i/B) | 3120: 4% slower / 4% slower (8.65 i/B) |
| twitterescaped | 3040 (10.70 i/B) | 3226: 6% faster / 6% faster (9.94 i/B) | 2869: 6% slower / 6% slower (11.64 i/B) | 3113: 2% faster / 2% faster (10.65 i/B) | 2852: 6% slower / 6% slower (10.50 i/B) |
| canada | 1969 (17.71 i/B) | 1961: 0% / 0% (17.71 i/B) | 2117: 8% faster / 8% faster (16.01 i/B) | 2113: 7% faster / 8% faster (16.54 i/B) | 2027: 3% faster / 3% faster (15.71 i/B) |
| citm_catalog | 3741 (9.18 i/B) | 3754: 0% / 1% faster (9.16 i/B) | 4696: 26% faster / 26% faster (7.02 i/B) | 4716: 26% faster / 27% faster (6.91 i/B) | 3813: 2% faster / 2% faster (7.17 i/B) |
| gsoc-2018 | 7069 (4.08 i/B) | 7353: 4% faster / 4% faster (4.02 i/B) | 6809: 4% slower / 3% slower (3.96 i/B) | 7091: 0% / 0% (3.84 i/B) | 7231: 2% faster / 2% faster (3.34 i/B) |
| github_events | 3955 (8.26 i/B) | 3981: 1% faster / 0% (8.17 i/B) | 3803: 4% slower / 4% slower (7.34 i/B) | 3844: 3% slower / 3% slower (7.25 i/B) | 3765: 5% slower / 5% slower (6.40 i/B) |

Load:  4:14  up  9:28, 2 users, load averages: 5.47 4.47 4.67  4:15  up  9:29, 2 users, load averages: 4.62 4.43 4.64 
