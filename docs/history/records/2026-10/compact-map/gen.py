import sys
k=int(sys.argv[1]); kind=sys.argv[2]
if kind=='int':
    key='i * 31 + j * 7'; T='Int'; pre=''
else:
    T='String'; pre=''
print('''use std.time

sub main()
  n = 100000
  k = %d
  names: List[String] = List()
  for j in 0..64
    !names.push(String("sym_name_", j))
  t0 = time.now()
  ms: List[Map[%s, Int]] = List()
  for i in 0..n
    m: Map[%s, Int] = Map()
    for j in 0..k
      !m.put(%s, j)
    !ms.push(<m)
  t1 = time.now()
  total = 0
  for _ in 0..10
    for i in 0..n
      for j in 0..k
        total += ms[i].get(%s) ?? 0
  t2 = time.now()
  print("build_ms", t1.since(t0) / 1000, "get_ms", t2.since(t1) / 1000, "total", total)
''' % (k, T, T, ('i * 31 + j * 7' if kind=='int' else '+names[(i + j) % 64]'), ('i * 31 + j * 7' if kind=='int' else '?names[(i + j) % 64]')))
