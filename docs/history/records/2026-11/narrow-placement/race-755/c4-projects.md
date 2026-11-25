# Race 755 at c4: each project's wall (median of rounds 1-10; M in ms, the others as a ratio to M)

| project | M | W | S | P | F | Q |
|---|---:|---:|---:|---:|---:|---:|
| Compiler | 77 | 0.996 | 1.005 | 1.001 | 0.989 | 1.004 |
| Compiler-Unions | 101 | 0.991 | 0.985 | 0.980 | 1.002 | 1.004 |
| cal-diy | 1185 | 0.997 | 0.997 | 0.998 | 0.989 | 0.999 |
| date-fns | 123 | 1.013 | 1.015 | 1.017 | 1.007 | 1.002 |
| drizzle-orm | 307 | 1.002 | 0.985 | 0.979 | 0.975 | 1.005 |
| formbricks-web | 1211 | 0.969 | 0.979 | 0.991 | 0.970 | 0.999 |
| mikro-orm | 1688 | 1.025 | 1.011 | 1.025 | 1.042 | 1.012 |
| next-packages-next | 644 | 1.014 | 1.016 | 1.023 | 1.009 | 1.010 |
| next-root | 373 | 1.014 | 1.026 | 1.020 | 1.000 | 0.993 |
| nuxt | 355 | 0.999 | 1.000 | 0.993 | 0.995 | 1.008 |
| playwright | 291 | 1.013 | 1.001 | 1.007 | 0.984 | 1.005 |
| storybook | 339 | 0.986 | 0.980 | 1.005 | 0.992 | 0.975 |
| supabase-studio | 1554 | 1.019 | 1.003 | 1.010 | 1.012 | 1.019 |
| typeorm | 216 | 1.022 | 1.020 | 1.021 | 1.012 | 1.010 |
| webpack | 363 | 1.014 | 1.020 | 1.021 | 1.006 | 1.003 |
| xstate-main | 211 | 1.022 | 1.019 | 1.022 | 1.012 | 1.004 |

## nuxt and webpack at c4: check time of each round (ms, sorted)

```
nuxt M check median 246 runs 241 241 243 246 246 247 247 251 253 253
nuxt W check median 254 runs 249 250 251 253 254 254 255 257 258 264
nuxt S check median 255 runs 242 245 247 254 255 255 256 256 258 266
nuxt P check median 251 runs 246 247 248 248 250 252 252 254 256 259
nuxt F check median 252 runs 243 245 248 251 252 253 253 259 261 268
nuxt Q check median 251 runs 238 242 243 245 250 252 257 257 257 258
webpack M check median 278 runs 264 271 271 274 278 278 283 286 287 288
webpack W check median 282 runs 279 279 280 281 281 282 282 283 292 294
webpack S check median 285 runs 275 275 277 277 283 287 288 290 290 297
webpack P check median 285 runs 276 276 279 283 284 286 287 287 287 291
webpack F check median 276 runs 267 271 272 275 275 278 280 282 288 289
webpack Q check median 278 runs 270 271 274 275 275 280 281 281 282 291
```
