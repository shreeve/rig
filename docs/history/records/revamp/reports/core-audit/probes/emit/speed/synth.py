#!/usr/bin/env python3
"""Synthesize a large Rig program from a ~110-line unit replicated N times."""
import sys

UNIT = '''
# ---- unit {n} ----
enum Shape{n}
  circle(radius: Int)
  rect(w: Int, h: Int)
  point

fun area{n}(s: ?Shape{n}) -> Int
  match s
    .circle(r) => return 3 * r * r
    .rect(w, h) => return w * h
    .point => return 0

struct Account{n}
  owner: String
  balance: Int

  fun doubled(?self) -> Int
    self.balance * 2

  sub deposit(!self, amount: Int)
    self.balance += amount

struct Stack{n}[T]
  items: Vec[T]

  sub push(!self, x: T)
    !self.items.push(<x)

  fun pop(!self) -> T?
    !self.items.pop()

  fun size(?self) -> Int
    self.items.len

struct Player{n}
  name: String
  score: Int

sub sort{n}[T](xs: ![]T, less: ?fun(?T, ?T) -> Bool)
  i = 1
  while i < xs.len : i += 1
    j = i
    while j > 0 and less(?xs[j], ?xs[j - 1]) : j -= 1
      !xs.swap(j, j - 1)

fun map{n}[T, U](xs: []T, f: ?fun(?T) -> U) -> Vec[U]
  out: Vec[U] = Vec()
  for x in xs
    !out.push(f(?x))
  out

fun max{n}[T](a: T, b: T) -> T
  a if a > b else b

fun balance_of{n}(a: ?Account{n}) -> Int
  a.balance

fun fib{n}(k: Int) -> Int
  a = 0
  b = 1
  i = 0
  while i < k : i += 1
    t = a + b
    a = b
    b = t
  a

fun classify{n}(x: Int) -> String
  if x < 0
    return "neg"
  if x == 0
    return "zero"
  "pos"

fun run{n}() -> Int
  shapes = [Shape{n}.circle(2), Shape{n}.rect(w: 3, h: {n} % 7 + 1), Shape{n}.point]
  total = 0
  for s in ?shapes
    total += area{n}(?s)
  acct = Account{n}(owner: "ada", balance: {n})
  !acct.deposit(5)
  total += balance_of{n}(?acct) + acct.doubled()
  moved = <acct
  total += moved.balance
  st = Stack{n}[String](items: Vec())
  !st.push("x")
  !st.push("yy")
  if !st.pop() as top
    total += top.len
  total += st.size()
  nums: Vec[Int] = Vec()
  for k in [5, 3, 8, 1]
    !nums.push(k + {n} % 3)
  compares = 0
  sort{n}(!nums[..], |!compares, a, b|
    compares += 1
    a < b)
  total += nums[0] + compares
  team = [Player{n}(name: "ada", score: 7), Player{n}(name: "bob", score: 9)]
  sort{n}(!team[..], |a, b| a.score > b.score)
  names = map{n}(?team[..], |p| p.name.len)
  total += names[0] + max{n}(fib{n}(10), {n})
  total += classify{n}(total - 100).len
  total
'''

def main():
    n = int(sys.argv[1])
    out = []
    for i in range(n):
        out.append(UNIT.format(n=i))
    out.append('\nsub main\n  sum = 0\n')
    for i in range(n):
        out.append(f'  sum += run{i}()\n')
    out.append('  print(sum)\n')
    sys.stdout.write(''.join(out))

main()
