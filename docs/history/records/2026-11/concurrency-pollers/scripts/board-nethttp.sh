#!/bin/bash
# board-nethttp.sh TAG: bench/net (20 rounds) and bench/http's load (10
# rounds), interleaved and rotated, every arm.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
ulimit -n 20000
python3 $S/board.py 20 $S/raw/net-$1.txt base=$S/net/base base2=$S/net/base2 own=$S/net/a spread=$S/net/b
python3 $S/http_ab.py 10 $S/raw/http-$1.txt $S/http/load base=$S/http/base base2=$S/http/base2 own=$S/http/a spread=$S/http/b
echo board-done
