#!/bin/bash
# usage: probe.sh name <<body   (body appended after a common prelude)
name=$1
{ cat <<'PRE'
struct P
  x: Int
  y: Int

struct S
  a: Vec[Int]
  b: Int

struct Q
  a: P
  b: Int

fun grow(v: !Vec[Int]) -> Int
  !v.push(7)
  2

fun bump(p: !P) -> Int
  p.x += 1
  0

fun rd(v: ?Vec[Int], n: Int) -> Int
  v.len + n

fun rp(p: P, n: Int) -> Int
  p.x + n

fun rs(s: []Int, n: Int) -> Int
  s.len + n

PRE
cat; } > $name.rig
echo "--- $name"
/Users/shreeve/Data/Code/rig-argfix/bin/rig run $name.rig 2>&1 | grep -v "^note: the package"
