# Writing tasks

Write each program in Rig, using the one-page guide. Each needs 5 to 25
lines. Every program starts at `sub main()`; `print(a, b)` prints its
values separated by spaces. Each task says what the program must print.

## 1. Append to a list you are given

Write `sub add_tags(tags, extra)` that appends every String in `extra`
to the end of `tags` and returns nothing. It must not change `extra`.
In `main`, make a `Vec[String]` holding `"red"` and another holding
`"blue"` and `"green"`, call `add_tags`, then print `tags` and the
length of the second list.

Prints: `["red", "blue", "green"] 2`

## 2. Return a view of the first element

Given

```
struct Book
  title: String
  pages: Int
```

write `fun first(books) -> ...` that returns the first book as a view,
without copying or removing it. In `main`, put two books on a shelf
(`Dune`, 412 pages, then `Emma`, 320 pages), call `first`, and print
the result's title and pages.

Prints: `Dune 412`

## 3. Take ownership and close a resource

Given

```
struct Conn
  host: String
```

give `Conn` a drop body that prints `closed` and the host. Write
`sub finish(c)` that takes ownership of a connection and prints
`finishing` and the host. In `main`, make a connection to `"db1"`, hand
it to `finish`, then print `after finish`. The connection must be
closed before `after finish` is printed.

Prints:
```
finishing db1
closed db1
after finish
```

## 4. Clone a list and change the copy

In `main`, make a `Vec[Int]` holding 1 and 2. Make an independent copy,
append 3 to the copy, set the copy's first element to 10, and print
both lists.

Prints: `[1, 2] [10, 2, 3]`

## 5. Pop until empty, using each value

In `main`, make a `Vec[Int]` holding 4, 5 and 6. In a loop, remove the
last element until the list is empty, printing `took` and each value
and adding it to a running total. Then print the total and the list's
length.

Prints:
```
took 6
took 5
took 4
15 0
```

## 6. Negate a condition that calls a method

Given

```
struct Cart
  items: Vec[String]
```

give `Cart` a method `is_empty` that only reads the cart. Write
`sub checkout(c)`, which only reads the cart: when the cart is not
empty it prints `paying for` and the number of items, and otherwise
`nothing to pay`. Write the test as a negation of `is_empty()`. In
`main`, check out an empty cart, add `"tea"`, and check out again.

Prints:
```
nothing to pay
paying for 1
```
