#!/bin/sh
# from a folder holding micro (rig build --release micro.rig) and rmicro/ (cargo build --release)
for r in 1 2 3 4 5 6; do ./micro | sed 's/^/rig /'; ./rmicro/target/release/rmicro | sed 's/^/rust /'; done
