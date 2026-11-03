| measure | variant | runs | fastest | median | fastest vs base | median vs base |
|---|---|---:|---:|---:|---|---|
| fannkuchredux wall | base | 10 | 6745.2 ms | 7663.5 ms |  |  |
| fannkuchredux wall | turn-1 | 10 | 7216.2 ms | 8210.8 ms | 7.0% slower | 7.1% slower |
| fannkuchredux wall | turn-3 | 10 | 6930.9 ms | 7493.0 ms | 2.8% slower | 2.3% faster |
| fannkuchredux wall | callfree | 10 | 5951.7 ms | 7570.8 ms | 13.3% faster | 1.2% faster |
| fannkuchredux wall | entry_callfree | 10 | 6831.7 ms | 7587.0 ms | 1.3% slower | 1.0% faster |
| fannkuchredux wall | entry_turn-1 | 10 | 6645.7 ms | 8135.2 ms | 1.5% faster | 6.2% slower |
| fannkuchredux-fast wall | base | 10 | 3050.4 ms | 3441.9 ms |  |  |
| fannkuchredux-fast wall | turn-1 | 10 | 2882.0 ms | 3364.0 ms | 5.8% faster | 2.3% faster |
| fannkuchredux-fast wall | turn-3 | 10 | 1844.4 ms | 2263.9 ms | 65.4% faster | 52.0% faster |
| fannkuchredux-fast wall | callfree | 10 | 2686.0 ms | 3427.4 ms | 13.6% faster | 0.4% faster |
| fannkuchredux-fast wall | entry_callfree | 10 | 2636.6 ms | 3505.3 ms | 15.7% faster | 1.8% slower |
| fannkuchredux-fast wall | entry_turn-1 | 10 | 2738.5 ms | 3416.3 ms | 11.4% faster | 0.8% faster |
| knucleotide-fast wall | base | 10 | 684.8 ms | 834.6 ms |  |  |
| knucleotide-fast wall | turn-1 | 10 | 680.4 ms | 863.7 ms | 0.7% faster | 3.5% slower |
| knucleotide-fast wall | turn-3 | 10 | 681.9 ms | 869.2 ms | 0.4% faster | 4.1% slower |
| knucleotide-fast wall | callfree | 10 | 683.4 ms | 854.5 ms | 0.2% faster | 2.4% slower |
| knucleotide-fast wall | entry_callfree | 10 | 668.5 ms | 850.3 ms | 2.4% faster | 1.9% slower |
| knucleotide-fast wall | entry_turn-1 | 10 | 682.2 ms | 831.9 ms | 0.4% faster | 0.3% faster |
| tasks fanout | base | 10 | 87.4 ms | 101.6 ms |  |  |
| tasks fanout | turn-1 | 10 | 82.8 ms | 89.3 ms | 5.5% faster | 13.8% faster |
| tasks fanout | turn-3 | 10 | 87.6 ms | 102.9 ms | 0.3% slower | 1.3% slower |
| tasks fanout | callfree | 10 | 86.9 ms | 99.5 ms | 0.6% faster | 2.2% faster |
| tasks fanout | entry_callfree | 10 | 87.5 ms | 96.0 ms | 0.1% slower | 5.9% faster |
| tasks fanout | entry_turn-1 | 10 | 83.0 ms | 92.9 ms | 5.2% faster | 9.4% faster |
| tasks hog | base | 10 | 59 us | 122 us |  |  |
| tasks hog | turn-1 | 10 | 4.8 ms | 7.6 ms | 8086.4% slower | 6161.7% slower |
| tasks hog | turn-3 | 10 | 10 us | 904 us | 490.0% faster | 643.6% slower |
| tasks hog | callfree | 10 | 85 us | 128 us | 44.1% slower | 4.9% slower |
| tasks hog | entry_callfree | 10 | 92 us | 152 us | 55.9% slower | 25.1% slower |
| tasks hog | entry_turn-1 | 10 | 5.9 ms | 7.6 ms | 9827.1% slower | 6150.6% slower |
| tasks wall | base | 10 | 513.8 ms | 614.2 ms |  |  |
| tasks wall | turn-1 | 10 | 496.1 ms | 566.9 ms | 3.6% faster | 8.3% faster |
| tasks wall | turn-3 | 10 | 519.2 ms | 648.6 ms | 1.0% slower | 5.6% slower |
| tasks wall | callfree | 10 | 492.9 ms | 617.0 ms | 4.3% faster | 0.5% slower |
| tasks wall | entry_callfree | 10 | 494.6 ms | 589.5 ms | 3.9% faster | 4.2% faster |
| tasks wall | entry_turn-1 | 10 | 481.3 ms | 555.1 ms | 6.8% faster | 10.7% faster |
