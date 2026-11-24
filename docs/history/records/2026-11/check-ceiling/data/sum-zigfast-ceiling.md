| project | mode | runs | zigfast instructions | ceiling instructions | fewer instructions | zigfast cycles | ceiling cycles | fewer cycles | zigfast wall s | ceiling wall s | faster (wall) | stdout |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Compiler | noCheck | 11/11 | 0.773B | 0.689B | 10.8% | 0.202B | 0.191B | 5.3% | 0.050 | 0.040 | 20.0% | identical |
| Compiler | full | 11/11 | 1.916B | 1.713B | 10.6% | 0.532B | 0.500B | 5.9% | 0.120 | 0.120 | 0.0% | identical |
| webpack | noCheck | 11/11 | 2.896B | 2.666B | 7.9% | 0.837B | 0.770B | 8.0% | 0.210 | 0.180 | 14.3% | identical |
| webpack | full | 11/11 | 11.491B | 10.379B | 9.7% | 3.149B | 2.989B | 5.1% | 0.750 | 0.700 | 6.7% | identical |
| supabase-studio | noCheck | 11/11 | 13.831B | 13.225B | 4.4% | 3.979B | 3.931B | 1.2% | 0.950 | 0.920 | 3.2% | identical |
| supabase-studio | full | 11/11 | 46.486B | 43.308B | 6.8% | 12.818B | 12.562B | 2.0% | 3.000 | 2.980 | 0.7% | identical |
