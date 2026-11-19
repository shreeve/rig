#!/bin/bash
# spin.sh: probe-rayon with SPIN_MS=200 (it spins 200 ms on its main
# thread after building the input, before the timed psum).
SPIN_MS=200 exec "$(dirname "$0")/bin/probe-rayon"
