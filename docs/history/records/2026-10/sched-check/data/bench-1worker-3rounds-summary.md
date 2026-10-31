| measure | variant | runs | fastest | median | fastest vs base | median vs base |
|---|---|---:|---:|---:|---|---|
| fannkuchredux-fast wall | base | 3 | 17247.8 ms | 17495.1 ms |  |  |
| fannkuchredux-fast wall | turn-1 | 3 | 16954.4 ms | 17207.1 ms | 1.7% faster | 1.7% faster |
| fannkuchredux-fast wall | turn-3 | 3 | 11580.8 ms | 11781.2 ms | 48.9% faster | 48.5% faster |
| fannkuchredux-fast wall | callfree | 3 | 17433.0 ms | 17444.5 ms | 1.1% slower | 0.3% faster |
| fannkuchredux-fast wall | entry_callfree | 3 | 17383.5 ms | 17423.0 ms | 0.8% slower | 0.4% faster |
| fannkuchredux-fast wall | entry_turn-1 | 3 | 16357.0 ms | 17102.3 ms | 5.4% faster | 2.3% faster |
| knucleotide-fast wall | base | 3 | 1933.1 ms | 1989.3 ms |  |  |
| knucleotide-fast wall | turn-1 | 3 | 1735.5 ms | 1943.1 ms | 11.4% faster | 2.4% faster |
| knucleotide-fast wall | turn-3 | 3 | 1750.0 ms | 1887.2 ms | 10.5% faster | 5.4% faster |
| knucleotide-fast wall | callfree | 3 | 1754.5 ms | 1983.8 ms | 10.2% faster | 0.3% faster |
| knucleotide-fast wall | entry_callfree | 3 | 1754.1 ms | 2070.2 ms | 10.2% faster | 4.1% slower |
| knucleotide-fast wall | entry_turn-1 | 3 | 1614.2 ms | 1788.7 ms | 19.8% faster | 11.2% faster |
