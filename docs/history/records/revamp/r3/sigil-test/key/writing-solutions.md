# Writing tasks: solutions (variant A)

Each solution was compiled and run with `bin/rig run`, and runs clean under
`RIG_SANITIZE=1`. The sources are `key/writing/w1.rig` ... `w6.rig`. The
table under each solution gives the sigil choices to score in each variant.
Other correct solutions exist: for example, a bare `add_tags(!tags, more)`
is as right as the written read lend `?more` (both checked); score one by
whether it compiles and prints the expected output, then by its sigils.

## 1. Append to a list you are given

```rig
sub add_tags(tags: !Vec[String], extra: ?Vec[String])
  for t in extra
    !tags.push(t)

sub main()
  tags: Vec[String] = Vec()
  !tags.push("red")
  more: Vec[String] = Vec()
  !more.push("blue")
  !more.push("green")
  add_tags(!tags, ?more)
  print(tags, more.len)
```

Output:

```
["red", "blue", "green"] 2
```

| Variant | Key spellings |
|---|---|
| A | `extra: ?Vec[String]`, `tags: !Vec[String]`, `!tags.push(t)`, `add_tags(!tags, ?more)` or `more` |
| B | `extra: &Vec[String]`, `tags: !Vec[String]`, `!tags.push(t)`, `add_tags(!tags, &more)` or `more` |
| C | `extra: &Vec[String]`, `tags: @Vec[String]`, `@tags.push(t)`, `add_tags(@tags, &more)` or `more` |
| D | same as C |

## 2. Return a view of the first element

```rig
struct Book
  title: String
  pages: Int

fun first(books: ?Vec[Book]) -> ?Book
  ?books[0]

sub main()
  shelf: Vec[Book] = Vec()
  !shelf.push(Book(title: "Dune", pages: 412))
  !shelf.push(Book(title: "Emma", pages: 320))
  b = first(?shelf)
  print(b.title, b.pages)
```

Output:

```
Dune 412
```

| Variant | Key spellings |
|---|---|
| A | `books: ?Vec[Book]`, `-> ?Book`, `?books[0]` |
| B | `books: &Vec[Book]`, `-> &Book`, `&books[0]` |
| C | same as B |
| D | same as B |

## 3. Take ownership and close a resource

```rig
struct Conn
  host: String

  drop(!self)
    print("closed", self.host)

sub finish(c: Conn)
  print("finishing", c.host)

sub main()
  c = Conn(host: "db1")
  finish(<c)
  print("after finish")
```

Output:

```
finishing db1
closed db1
after finish
```

| Variant | Key spellings |
|---|---|
| A | `finish(<c)`; `drop(!self)` |
| B | `finish(<c)`; `drop(!self)` |
| C | `finish(<c)`; `drop(@self)` |
| D | same as C |

## 4. Clone a list and change the copy

```rig
sub main()
  a: Vec[Int] = Vec()
  !a.push(1)
  !a.push(2)
  b = +a
  !b.push(3)
  b[0] = 10
  print(a, b)
```

Output:

```
[1, 2] [10, 2, 3]
```

| Variant | Key spellings |
|---|---|
| A | `b = +a`, `!b.push(3)` |
| B | `b = +a`, `!b.push(3)` |
| C | `b = +a`, `@b.push(3)` |
| D | same as C |

## 5. Pop until empty, using each value

```rig
sub main()
  stack: Vec[Int] = Vec()
  !stack.push(4)
  !stack.push(5)
  !stack.push(6)
  total = 0
  while (!stack).pop() as x
    print("took", x)
    total += x
  print(total, stack.len)
```

Output:

```
took 6
took 5
took 4
15 0
```

| Variant | Key spellings |
|---|---|
| A | `while (!stack).pop() as x` |
| B | `while (!stack).pop() as x` |
| C | `while @stack.pop() as x` |
| D | same as C |

## 6. Negate a condition that calls a method

```rig
struct Cart
  items: Vec[String]

  fun is_empty(?self) -> Bool
    self.items.len == 0

sub checkout(c: ?Cart)
  if not c.is_empty()
    print("paying for", c.items.len)
  else
    print("nothing to pay")

sub main()
  c = Cart(items: Vec())
  checkout(c)
  !c.items.push("tea")
  checkout(c)
```

Output:

```
nothing to pay
paying for 1
```

| Variant | Key spellings |
|---|---|
| A | `fun is_empty(?self)`, `c: ?Cart`, `if not c.is_empty()`, `!c.items.push("tea")` |
| B | `fun is_empty(&self)`, `c: &Cart`, `if not c.is_empty()`, `!c.items.push("tea")` |
| C | `fun is_empty(&self)`, `c: &Cart`, `if not c.is_empty()`, `@c.items.push("tea")` |
| D | `fun is_empty(&self)`, `c: &Cart`, `if !c.is_empty()`, `@c.items.push("tea")` |
