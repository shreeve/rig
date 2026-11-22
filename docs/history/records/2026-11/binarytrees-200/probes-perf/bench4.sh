#!/bin/bash
cd "$(dirname "$0")"
for m in b16 b16p b16d nb b8 fl; do echo -n "$m: "; ./floor4 $m 10 21 2>&1 >/dev/null | tail -1; done
echo -n "b16 depth: "; SPLIT=depth ./floor4 b16 10 21 2>&1 >/dev/null | tail -1
echo -n "b16p depth: "; SPLIT=depth ./floor4 b16p 10 21 2>&1 >/dev/null | tail -1
echo -n "nb depth: "; SPLIT=depth ./floor4 nb 10 21 2>&1 >/dev/null | tail -1
echo -n "b16 again: "; /usr/bin/time ./floor4 b16 10 21 2>&1 >/dev/null | tail -2 | tr '\n' ' '; echo
