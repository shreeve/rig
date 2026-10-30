#!/bin/sh
# mk.sh: one root file per variant, built ReleaseFast as rig build --release=fast builds
cd "$(dirname "$0")"
v() { name=$1; shift; printf 'const c = @import("ceil.zig");\npub const main = c.Main(.{ %s }).main;\n' "$*" > v_$name.zig; }
v rig         ''
v base        '.mix = false'
v base_regs   '.mix = false, .escape = false'
v base_tag    '.mix = false, .tag_table = false'
v base_len    '.mix = false, .len_store = false'
v base_index  '.mix = false, .index_trip = false'
v base_peel   '.mix = false, .claim_first = false'
v ceil        '.mix = false, .escape = false, .tag_table = false, .len_store = false, .index_trip = false, .claim_first = false'
v ceil_mix    '.escape = false, .tag_table = false, .len_store = false, .index_trip = false, .claim_first = false'
v ceil_tick   '.mix = false, .escape = false, .tag_table = false, .len_store = false, .index_trip = false, .claim_first = false, .tick = true'
v base_tick   '.mix = false, .tick = true'
v ceil_fold   '.mix = false, .escape = false, .tag_table = false, .len_store = false, .index_trip = false, .claim_first = false, .fold_hash = true'
v ceil_keeptag '.mix = false, .escape = false, .len_store = false, .index_trip = false, .claim_first = false'
v ceil_keepregs '.mix = false, .tag_table = false, .len_store = false, .index_trip = false, .claim_first = false'
v ceil_keepindex '.mix = false, .escape = false, .tag_table = false, .len_store = false, .claim_first = false'
v ceil_keeppeel '.mix = false, .escape = false, .tag_table = false, .len_store = false, .index_trip = false'
mkdir -p bin
for f in v_*.zig; do n=${f#v_}; n=${n%.zig}; [ -n "$ONLY" ] && case " $ONLY " in *" $n "*) ;; *) continue;; esac
  zig build-exe -O ReleaseFast -fomit-frame-pointer --cache-dir .zig-cache -femit-bin=bin/$n $f || exit 1; done
rm -f bin/*.o
