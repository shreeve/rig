#!/bin/bash
# nosig.sh: the monitor arm (bin2/mon) sending no signals.
CEIL_NOSIG=1 exec "$(dirname "$0")/bin2/mon"
