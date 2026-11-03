| measure | variant | runs | fastest | median | fastest vs base | median vs base |
|---|---|---:|---:|---:|---|---|
| fannkuchredux wall | base | 10 | 5238.5 ms | 6567.6 ms |  |  |
| fannkuchredux wall | turn-1 | 10 | 5793.2 ms | 6323.6 ms | 10.6% slower | 3.9% faster |
| fannkuchredux wall | turn-3 | 10 | 5333.8 ms | 6397.1 ms | 1.8% slower | 2.7% faster |
| fannkuchredux wall | callfree | 10 | 5332.5 ms | 6725.6 ms | 1.8% slower | 2.4% slower |
| fannkuchredux wall | entry_callfree | 10 | 5262.2 ms | 6879.9 ms | 0.5% slower | 4.8% slower |
| fannkuchredux wall | entry_turn-1 | 10 | 6143.0 ms | 7686.9 ms | 17.3% slower | 17.0% slower |
| fannkuchredux-fast wall | base | 10 | 2203.1 ms | 2916.3 ms |  |  |
| fannkuchredux-fast wall | turn-1 | 10 | 2092.7 ms | 3253.4 ms | 5.3% faster | 11.6% slower |
| fannkuchredux-fast wall | turn-3 | 10 | 1360.2 ms | 1556.3 ms | 62.0% faster | 87.4% faster |
| fannkuchredux-fast wall | callfree | 10 | 2095.8 ms | 2848.2 ms | 5.1% faster | 2.4% faster |
| fannkuchredux-fast wall | entry_callfree | 10 | 2036.0 ms | 2875.5 ms | 8.2% faster | 1.4% faster |
| fannkuchredux-fast wall | entry_turn-1 | 10 | 2008.3 ms | 2780.7 ms | 9.7% faster | 4.9% faster |
| knucleotide-fast wall | base | 10 | 576.2 ms | 640.8 ms |  |  |
| knucleotide-fast wall | turn-1 | 10 | 579.9 ms | 634.7 ms | 0.7% slower | 1.0% faster |
| knucleotide-fast wall | turn-3 | 10 | 566.2 ms | 628.0 ms | 1.8% faster | 2.0% faster |
| knucleotide-fast wall | callfree | 10 | 572.4 ms | 673.6 ms | 0.7% faster | 5.1% slower |
| knucleotide-fast wall | entry_callfree | 10 | 567.6 ms | 643.4 ms | 1.5% faster | 0.4% slower |
| knucleotide-fast wall | entry_turn-1 | 10 | 551.8 ms | 625.2 ms | 4.4% faster | 2.5% faster |
| tasks fanout | base | 10 | 84.2 ms | 97.3 ms |  |  |
| tasks fanout | turn-1 | 10 | 78.6 ms | 88.8 ms | 7.1% faster | 9.6% faster |
| tasks fanout | turn-3 | 10 | 88.8 ms | 95.8 ms | 5.5% slower | 1.6% faster |
| tasks fanout | callfree | 10 | 87.4 ms | 96.6 ms | 3.8% slower | 0.7% faster |
| tasks fanout | entry_callfree | 10 | 87.5 ms | 93.7 ms | 3.9% slower | 3.8% faster |
| tasks fanout | entry_turn-1 | 10 | 82.8 ms | 90.5 ms | 1.7% faster | 7.6% faster |
| tasks hog | base | 10 | 64 us | 134 us |  |  |
| tasks hog | turn-1 | 10 | 4.9 ms | 5.3 ms | 7514.1% slower | 3845.7% slower |
| tasks hog | turn-3 | 10 | 9 us | 780 us | 611.1% faster | 484.3% slower |
| tasks hog | callfree | 10 | 85 us | 126 us | 32.8% slower | 6.0% faster |
| tasks hog | entry_callfree | 10 | 76 us | 116 us | 18.8% slower | 14.6% faster |
| tasks hog | entry_turn-1 | 10 | 3.6 ms | 5.2 ms | 5568.8% slower | 3830.7% slower |
| tasks wall | base | 10 | 410.2 ms | 459.2 ms |  |  |
| tasks wall | turn-1 | 10 | 401.0 ms | 451.5 ms | 2.3% faster | 1.7% faster |
| tasks wall | turn-3 | 10 | 441.8 ms | 494.8 ms | 7.7% slower | 7.8% slower |
| tasks wall | callfree | 10 | 417.5 ms | 465.2 ms | 1.8% slower | 1.3% slower |
| tasks wall | entry_callfree | 10 | 421.5 ms | 517.9 ms | 2.7% slower | 12.8% slower |
| tasks wall | entry_turn-1 | 10 | 404.4 ms | 450.7 ms | 1.5% faster | 1.9% faster |
