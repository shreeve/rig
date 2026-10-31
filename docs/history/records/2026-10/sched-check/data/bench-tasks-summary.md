| measure | variant | runs | fastest | median | fastest vs base | median vs base |
|---|---|---:|---:|---:|---|---|
| tasks fanout | base | 10 | 90.6 ms | 105.0 ms |  |  |
| tasks fanout | turn-1 | 10 | 92.5 ms | 99.0 ms | 2.1% slower | 6.1% faster |
| tasks fanout | turn-3 | 10 | 89.6 ms | 109.9 ms | 1.1% faster | 4.7% slower |
| tasks fanout | callfree | 10 | 86.8 ms | 103.8 ms | 4.3% faster | 1.1% faster |
| tasks fanout | entry_callfree | 10 | 92.4 ms | 105.3 ms | 2.0% slower | 0.2% slower |
| tasks fanout | entry_turn-1 | 10 | 92.6 ms | 98.6 ms | 2.2% slower | 6.5% faster |
| tasks hog | base | 10 | 91 us | 119 us |  |  |
| tasks hog | turn-1 | 10 | 4.5 ms | 6.0 ms | 4869.2% slower | 4974.7% slower |
| tasks hog | turn-3 | 10 | 552 us | 818 us | 506.6% slower | 590.3% slower |
| tasks hog | callfree | 10 | 86 us | 117 us | 5.8% faster | 1.3% faster |
| tasks hog | entry_callfree | 10 | 84 us | 132 us | 8.3% faster | 11.8% slower |
| tasks hog | entry_turn-1 | 10 | 4.7 ms | 6.0 ms | 5103.3% slower | 4957.4% slower |
| tasks wall | base | 10 | 444.7 ms | 495.0 ms |  |  |
| tasks wall | turn-1 | 10 | 457.8 ms | 491.6 ms | 2.9% slower | 0.7% faster |
| tasks wall | turn-3 | 10 | 451.7 ms | 534.7 ms | 1.6% slower | 8.0% slower |
| tasks wall | callfree | 10 | 434.9 ms | 510.0 ms | 2.3% faster | 3.0% slower |
| tasks wall | entry_callfree | 10 | 439.3 ms | 498.3 ms | 1.2% faster | 0.7% slower |
| tasks wall | entry_turn-1 | 10 | 440.4 ms | 488.8 ms | 1.0% faster | 1.3% faster |
