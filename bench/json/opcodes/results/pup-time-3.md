 04:15:31 up 15 days, 22:23,  3 users,  load average: 1.09, 7.16, 18.18
MB/s (fastest of 15 interleaved runs) and the change against `base` in time / in cycles; instructions per byte last
| file | base | utf8_kl+esc_copy16+esc_hex16b | src:wsbits3+wsb_tbl+vread | ws_tbl+utf8_kl+esc_copy16+esc_hex16b+vread | src:wsbits3+wsb_tbl+utf8_kl+esc_copy16+esc_hex16b+vread | ext:sonic |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 2247 (10.95 i/B) | 2435: 8% faster / 8% faster (10.21 i/B) | 2454: 9% faster / 10% faster (9.92 i/B) | 2497: 11% faster / 11% faster (8.72 i/B) | 2719: 21% faster / 21% faster (8.99 i/B) | 2785: 24% faster / 25% faster (7.88 i/B) |
| twitterescaped | 2135 (12.23 i/B) | 2256: 6% faster / 6% faster (11.18 i/B) | 1965: 8% slower / 8% slower (13.08 i/B) | 2412: 13% faster / 13% faster (10.38 i/B) | 2169: 2% faster / 2% faster (11.75 i/B) | 2232: 5% faster / 5% faster (10.50 i/B) |
| canada | 1284 (19.35 i/B) | 1297: 1% faster / 1% faster (19.79 i/B) | 1342: 4% faster / 4% faster (17.29 i/B) | 1333: 4% faster / 4% faster (17.84 i/B) | 1341: 4% faster / 4% faster (17.32 i/B) | 1429: 11% faster / 12% faster (16.08 i/B) |
| citm_catalog | 2529 (10.17 i/B) | 2501: 1% slower / 1% slower (10.22 i/B) | 3414: 35% faster / 36% faster (7.40 i/B) | 3029: 20% faster / 20% faster (7.62 i/B) | 3439: 36% faster / 36% faster (7.40 i/B) | 3579: 41% faster / 42% faster (6.28 i/B) |
| gsoc-2018 | 4589 (4.57 i/B) | 4910: 7% faster / 7% faster (4.42 i/B) | 4747: 3% faster / 3% faster (4.26 i/B) | 4888: 7% faster / 6% faster (3.99 i/B) | 5047: 10% faster / 10% faster (4.10 i/B) | 5185: 13% faster / 14% faster (2.51 i/B) |
| github_events | 2729 (9.43 i/B) | 2731: 0% / 0% (9.36 i/B) | 3100: 14% faster / 14% faster (8.10 i/B) | 2840: 4% faster / 4% faster (7.68 i/B) | 3127: 15% faster / 15% faster (7.99 i/B) | 3865: 42% faster / 41% faster (5.37 i/B) |
 04:17:20 up 15 days, 22:25,  3 users,  load average: 1.24, 5.34, 16.28
