#!/bin/sh
cd /zfs/trig-pup/mem-census/src
export CARGO_TARGET_DIR=/zfs/trig-pup/mem-census/target CARGO_PROFILE_DEV_STRIP=none CARGO_PROFILE_DEV_DEBUG=line-tables-only CARGO_PROFILE_DEV_DEBUG_ASSERTIONS=false CARGO_PROFILE_DEV_OVERFLOW_CHECKS=false RUSTFLAGS="-C force-frame-pointers=yes"
exec sh /zfs/trig-pup/trial/slot.sh cargo build --locked -p tsrs_cli --bin tsrs --features tsrs_cli/noembed
