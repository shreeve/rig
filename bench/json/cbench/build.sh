#!/bin/sh
# usage: build.sh
# Clones simdjson and yyjson at pinned releases into ./upstream (once) and
# builds ./prog-simdjson-dom and ./prog-yyjson, each
# `prog FILE N`, which prints "<ns> <check>" as the other competitors do.
set -e
W=$(cd "$(dirname "$0")" && pwd)
cd "$W"
mkdir -p upstream
[ -d upstream/simdjson/.git ] || git clone -q --depth 1 --branch v3.10.1 https://github.com/simdjson/simdjson.git upstream/simdjson
[ -d upstream/yyjson/.git ] || git clone -q --depth 1 --branch 0.10.0 https://github.com/ibireme/yyjson.git upstream/yyjson
case $(uname -m) in arm64|aarch64) ARCH=-mcpu=native;; *) ARCH=-march=native;; esac
CXX=${CXX:-c++}; CC=${CC:-cc}
S=upstream/simdjson/singleheader
$CXX -O3 -DNDEBUG $ARCH -std=c++17 -I$S -c $S/simdjson.cpp -o simdjson.o
$CXX -O3 -DNDEBUG $ARCH -std=c++17 -I$S simdjson_dom.cpp simdjson.o -o prog-simdjson-dom
$CC -O3 -DNDEBUG $ARCH -std=c11 -Iupstream/yyjson/src yyjson_bench.c upstream/yyjson/src/yyjson.c -o prog-yyjson
