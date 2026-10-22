import os
P = {}
def p(name, src): P[name] = src.lstrip("\n")

# ---------- Python habits ----------
p("py01_def", """
def add(a: Int, b: Int) -> Int
  a + b

sub main
  print(add(1, 2))
""")
p("py02_elif", """
sub main
  x = 3
  if x > 5
    print("big")
  elif x > 1
    print("mid")
  else
    print("small")
""")
p("py03_colon_if", """
sub main
  x = 3
  if x > 1:
    print("yes")
""")
p("py04_True", """
sub main
  ok = True
  print(ok)
""")
p("py05_None", """
fun find(n: Int) -> Int?
  return None if n < 0
  n

sub main
  print(find(3) ?? 0)
""")
p("py06_len_fn", """
sub main
  xs = [1, 2, 3]
  print(len(xs))
""")
p("py07_dot_len_call", """
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  print(v.len())
""")
p("py08_append", """
sub main
  v: Vec[Int] = Vec()
  !v.append(1)
  print(v.len)
""")
p("py09_self_field_no_self", """
struct Person
  age: Int

  fun older(?self) -> Int
    age + 1

sub main
  p = Person(age: 3)
  print(p.older())
""")
p("py10_class", """
class Person
  age: Int

sub main
  p = Person(age: 3)
  print(p.age)
""")
p("py11_range_fn", """
sub main
  for i in range(5)
    print(i)
""")
p("py12_fstring", """
sub main
  name = "ada"
  print(f"hi {name}")
""")
p("py13_pass", """
sub nothing
  pass

sub main
  nothing()
""")
p("py14_and_symbols", """
sub main
  a = true
  b = false
  if a && b
    print("both")
""")
p("py15_not_bang", """
sub main
  a = true
  if !a
    print("no")
""")
p("py16_self_no_sigil", """
struct Counter
  n: Int

  sub bump(self)
    self.n += 1

sub main
  c = Counter(n: 0)
  c.bump()
  print(c.n)
""")
p("py17_str_concat", """
sub main
  a = "x"
  b = "y"
  print(a + b)
""")
p("py18_tuple_return", """
fun two -> (Int, Int)
  (1, 2)

sub main
  print(two())
""")
p("py19_list_type", """
fun total(xs: List[Int]) -> Int
  0

sub main
  print(0)
""")
p("py20_dict", """
sub main
  d = {"a": 1}
  print(d)
""")
p("py21_while_true", """
sub main
  n = 0
  while True
    n += 1
    break if n > 3
  print(n)
""")
p("py22_is_none", """
fun f(n: Int) -> Int?
  n

sub main
  x = f(1)
  if x is none
    print("none")
""")
p("py23_lambda", """
sub main
  f = lambda x: x + 1
  print(f(2))
""")
p("py24_str_method", """
sub main
  s = "hello"
  print(s.upper())
""")
p("py25_print_no_parens", """
sub main
  print "hi"
""")
p("py26_int_conv_str", """
sub main
  n = 5
  print(str(n))
""")
p("py27_misspelled_local", """
sub main
  total = 5
  print(totl)
""")
p("py28_misspelled_fn", """
fun compute(n: Int) -> Int
  n * 2

sub main
  print(compte(3))
""")
p("py29_misspelled_field", """
struct Point
  x: Int
  y: Int

sub main
  p = Point(x: 1, y: 2)
  print(p.z)
""")
p("py30_misspelled_method", """
struct Point
  x: Int

  fun double(?self) -> Int
    self.x * 2

sub main
  p = Point(x: 1)
  print(p.dubble())
""")
p("py31_misspelled_type", """
sub main
  x: Integer = 5
  print(x)
""")
p("py32_misspelled_kwarg", """
struct Point
  x: Int
  y: Int

sub main
  p = Point(x: 1, yy: 2)
  print(p.x)
""")
p("py33_positional_ctor", """
struct Point
  x: Int
  y: Int

sub main
  p = Point(1, 2)
  print(p.x)
""")
p("py34_tab_indent", "sub main\n\tprint(1)\n")
p("py35_mixed_indent", """
sub main
  x = 1
   print(x)
""")
p("py36_equals_in_if", """
sub main
  x = 1
  if x = 1
    print("one")
""")
p("py37_return_missing", """
fun f(n: Int) -> Int
  if n > 0
    return 1

sub main
  print(f(1))
""")
p("py38_int_div", """
sub main
  x: Float = 7 / 2
  print(x)
""")
p("py39_power", """
sub main
  print(2 ** 3)
""")
p("py40_ternary_py", """
sub main
  x = 3
  y = "a" if x > 1 else "b"
  z = x > 1 ? 1 : 2
  print(y, z)
""")

# ---------- Rust habits ----------
p("rs01_fn", """
fn add(a: Int, b: Int) -> Int
  a + b

sub main
  print(add(1, 2))
""")
p("rs02_let", """
sub main
  let x = 5
  print(x)
""")
p("rs03_let_mut", """
sub main
  let mut x = 5
  x += 1
  print(x)
""")
p("rs04_impl", """
struct P
  x: Int

impl P
  fun get(?self) -> Int
    self.x

sub main
  print(P(x: 1).get())
""")
p("rs05_ref_amp", """
fun f(x: &Int) -> Int
  x

sub main
  print(f(&3))
""")
p("rs06_amp_call", """
struct S
  n: Int

fun f(s: ?S) -> Int
  s.n

sub main
  s = S(n: 1)
  print(f(&s))
""")
p("rs07_as_cast", """
sub main
  x = 300
  y = x as U8
  print(y)
""")
p("rs08_semicolons", """
sub main
  x = 1;
  print(x);
""")
p("rs09_braces", """
sub main {
  print(1)
}
""")
p("rs10_match_arms_comma", """
enum C
  red
  green

sub main
  c: C = .red
  match c
    .red => print("r"),
    .green => print("g"),
""")
p("rs11_match_underscore", """
sub main
  n = 3
  match n
    1 => print("one")
    _ => print("other")
""")
p("rs12_question_on_error", """
error E
  bad

fun f(n: Int) -> Int!
  return E.bad if n < 0
  n

fun g -> Int!
  f(1)? + 1

sub main
  print(g()!)
""")
p("rs13_result_type", """
fun f(n: Int) -> Result[Int, String]
  n

sub main
  print(f(1))
""")
p("rs14_option_type", """
fun f(n: Int) -> Option[Int]
  n

sub main
  print(f(1))
""")
p("rs15_Some", """
fun f(n: Int) -> Int?
  Some(n)

sub main
  print(f(1) ?? 0)
""")
p("rs16_unwrap", """
fun f(n: Int) -> Int?
  n

sub main
  print(f(1).unwrap())
""")
p("rs17_println", """
sub main
  println!("hi")
""")
p("rs18_self_dot_no_sigil_mut", """
struct C
  n: Int

  sub bump(?self)
    self.n += 1

sub main
  c = C(n: 0)
  !c.bump()
  print(c.n)
""")
p("rs19_i32", """
sub main
  x: i32 = 5
  print(x)
""")
p("rs20_u8_lower", """
sub main
  x: u8 = 5
  print(x)
""")
p("rs21_clone_method", """
struct S
  v: Vec[Int]

sub main
  s = S(v: Vec())
  t = s.clone()
  print(t.v.len)
""")
p("rs22_trait", """
trait Show
  fun show(?self) -> String

sub main
  print(1)
""")
p("rs23_pub_fn", """
pub fn f -> Int
  1

sub main
  print(f())
""")
p("rs24_loop", """
sub main
  n = 0
  loop
    n += 1
    break if n > 2
  print(n)
""")
p("rs25_vec_macro", """
sub main
  v = vec![1, 2, 3]
  print(v.len)
""")
p("rs26_generic_angle", """
struct Box<T>
  v: T

sub main
  b = Box(v: 1)
  print(b.v)
""")
p("rs27_generic_angle_use", """
sub main
  v: Vec<Int> = Vec()
  print(v.len)
""")
p("rs28_return_type_colon", """
fun f(n: Int): Int
  n

sub main
  print(f(1))
""")

# ---------- C / Zig / JS habits ----------
p("c01_var", """
sub main
  var x = 5
  x += 1
  print(x)
""")
p("c02_const", """
sub main
  const x = 5
  print(x)
""")
p("c03_switch", """
sub main
  n = 1
  switch n
    1 => print("one")
    else => print("other")
""")
p("c04_plusplus", """
sub main
  i = 0
  i++
  print(i)
""")
p("c05_for_c_style", """
sub main
  for (i = 0; i < 3; i += 1)
    print(i)
""")
p("c06_null", """
fun f(n: Int) -> Int?
  return null if n < 0
  n

sub main
  print(f(1) ?? 0)
""")
p("c07_char_literal", """
sub main
  c: U8 = 'a'
  print(c)
""")
p("c08_js_function", """
function f(x)
  x

sub main
  print(f(1))
""")
p("c09_js_triple_eq", """
sub main
  x = 1
  print(x === 1)
""")
p("c10_zig_try", """
error E
  bad

fun f -> Int!
  1

fun g -> Int!
  try f()

sub main
  print(g()!)
""")
p("c11_zig_orelse", """
fun f -> Int?
  1

sub main
  print(f() orelse 0)
""")
p("c12_zig_ptr_star", """
fun f(p: *Int) -> Int
  p

sub main
  x = 1
  print(f(&x))
""")
p("c13_int_suffix", """
sub main
  x = 5u8
  print(x)
""")
p("c14_leading_zero", """
sub main
  x = 007
  print(x)
""")
p("c15_void", """
fun f -> void
  print(1)

sub main
  f()
""")
p("c16_return_in_sub_value", """
sub f
  return 1

sub main
  f()
""")
p("c17_array_decl_c", """
sub main
  int xs[3] = [1, 2, 3]
  print(xs)
""")
p("c18_null_coalesce_js", """
fun f -> Int?
  none

sub main
  x = f() || 0
  print(x)
""")
p("c19_else_if", """
sub main
  x = 3
  if x > 5
    print("big")
  else if x > 1
    print("mid")
""")

# ---------- Rig sigil / rule misuse ----------
p("rg01_missing_read_borrow_arg", """
struct S
  n: Int

fun f(s: ?S) -> Int
  s.n

sub main
  s = S(n: 1)
  print(f(s))
""")
p("rg02_missing_write_borrow_arg", """
sub bump(n: !Int)
  n += 1

sub main
  x = 1
  bump(x)
  print(x)
""")
p("rg03_use_after_move", """
struct S
  v: Vec[Int]

sub take(s: S)
  print(s.v.len)

sub main
  s = S(v: Vec())
  take(<s)
  print(s.v.len)
""")
p("rg04_implicit_move", """
struct S
  v: Vec[Int]

sub take(s: S)
  print(s.v.len)

sub main
  s = S(v: Vec())
  take(s)
""")
p("rg05_push_no_bang", """
sub main
  v: Vec[Int] = Vec()
  v.push(1)
  print(v.len)
""")
p("rg06_for_vec_bare", """
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  for x in v
    print(x)
""")
p("rg07_bang_negation", """
sub main
  done = false
  while !done
    done = true
  print(done)
""")
p("rg08_unused_local", """
sub main
  x = 1
  print(2)
""")
p("rg09_shadow", """
sub main
  x = 1
  print(x)
  for x in 0..3
    print(x)
""")
p("rg10_fixed_reassign", """
sub main
  x =! 1
  x = 2
  print(x)
""")
p("rg11_fallible_bare_call", """
error E
  bad

fun f -> Int!
  1

sub main
  print(f())
""")
p("rg12_bang_noncallfail", """
fun f -> Int
  1

sub main
  print(f()!)
""")
p("rg13_optional_as_value", """
fun f -> Int?
  1

sub main
  x = f()
  print(x + 1)
""")
p("rg14_sub_returns_value", """
sub f -> Int
  1

sub main
  print(f())
""")
p("rg15_fun_no_return_type", """
fun f
  1

sub main
  print(f())
""")
p("rg16_move_borrowed", """
struct S
  v: Vec[Int]

sub take(s: S)
  print(s.v.len)

sub g(s: ?S)
  take(<s)

sub main
  s = S(v: Vec())
  g(?s)
""")
p("rg17_return_borrow_of_local", """
struct S
  n: Int

fun mk -> ?S
  s = S(n: 1)
  ?s

sub main
  print(mk().n)
""")
p("rg18_sigil_space", """
struct S
  v: Vec[Int]

sub take(s: S)
  print(s.v.len)

sub main
  s = S(v: Vec())
  take(< s)
""")
p("rg19_clone_copy", """
sub main
  x = 5
  y = +x
  print(y)
""")
p("rg20_drop_copy", """
sub main
  x = 5
  -x
""")
p("rg21_shared_mutate", """
struct S
  n: Int

sub main
  s = *S(n: 1)
  s.n = 2
  print(s.n)
""")
p("rg22_weak_deref", """
struct S
  n: Int

sub main
  s = *S(n: 1)
  w = ~s
  print(w.n)
""")
p("rg23_match_nonexhaustive", """
enum C
  red
  green
  blue

sub main
  c: C = .red
  match c
    .red => print("r")
    .green => print("g")
""")
p("rg24_enum_no_dot", """
enum C
  red
  green

sub main
  c: C = red
  print(c == C.red)
""")
p("rg25_method_write_on_read_self", """
struct C
  n: Int

  fun get(?self) -> Int
    self.n = 3
    self.n

sub main
  c = C(n: 0)
  print(c.get())
""")
p("rg26_call_write_method_no_bang", """
struct C
  n: Int

  sub bump(!self)
    self.n += 1

sub main
  c = C(n: 0)
  c.bump()
  print(c.n)
""")
p("rg27_string_index_assign", """
sub main
  s = "abc"
  s[0] = 65
  print(s)
""")
p("rg28_int_plus_float", """
sub main
  a = 1
  b = 2.5
  print(a + b)
""")
p("rg29_wrong_arity", """
fun add(a: Int, b: Int) -> Int
  a + b

sub main
  print(add(1))
""")
p("rg30_wrong_arg_type", """
fun add(a: Int, b: Int) -> Int
  a + b

sub main
  print(add(1, "2"))
""")
p("rg31_missing_main", """
fun f -> Int
  1
""")
p("rg32_main_is_fun", """
fun main
  print(1)
""")
p("rg33_kwarg_equals", """
struct P
  x: Int

sub main
  p = P(x = 1)
  print(p.x)
""")
p("rg34_optional_propagate_in_sub", """
fun f -> Int?
  1

sub main
  x = f()?
  print(x)
""")
p("rg35_if_as_on_nonoptional", """
sub main
  x = 1
  if x as y
    print(y)
""")
p("rg36_borrow_of_temp_stored", """
struct S
  n: Int

struct H
  s: ?S

sub main
  h = H(s: ?S(n: 1))
  print(h.s.n)
""")
p("rg37_generic_angle_call", """
fun max[T](a: T, b: T) -> T
  a if a > b else b

sub main
  print(max<Int>(1, 2))
""")
p("rg38_vec_literal", """
sub main
  v: Vec[Int] = [1, 2, 3]
  print(v.len)
""")
p("rg39_array_push", """
sub main
  xs = [1, 2, 3]
  !xs.push(4)
  print(xs.len)
""")
p("rg40_neg_index", """
sub main
  xs = [1, 2, 3]
  print(xs[-1])
""")
p("rg41_self_in_fun_w_o_param", """
struct P
  x: Int

  fun get -> Int
    self.x

sub main
  print(P(x: 1).get())
""")
p("rg42_new_ctor", """
struct P
  x: Int

sub main
  p = new P(x: 1)
  print(p.x)
""")
p("rg43_P_new", """
struct P
  x: Int

sub main
  p = P.new(x: 1)
  print(p.x)
""")
p("rg44_string_mul", """
sub main
  print("ab" * 3)
""")
p("rg45_write_borrow_twice", """
sub two(a: !Int, b: !Int)
  a += b

sub main
  x = 1
  two(!x, !x)
  print(x)
""")
p("rg46_move_in_loop", """
struct S
  v: Vec[Int]

sub take(s: S)
  print(s.v.len)

sub main
  s = S(v: Vec())
  for i in 0..2
    take(<s)
""")
p("rg47_uninit_decl", """
sub main
  x: Int
  x = 5
  print(x)
""")
p("rg48_error_decl_enum_like", """
error E
  bad

fun f -> Int!
  return .bad
  1

sub main
  print(f() catch 0)
""")
p("rg49_catch_no_e", """
error E
  bad

fun f -> Int!
  return E.bad

sub main
  x = f() catch |e| 0
  print(x)
""")
p("rg50_sub_main_parens_args", """
sub main(args: []String)
  print(1)
""")
p("rg51_optional_field_access", """
struct P
  x: Int

fun f -> P?
  P(x: 1)

sub main
  print(f().x)
""")
p("rg52_compare_optional_none_eq", """
fun f -> Int?
  none

sub main
  if f() == none
    print("none")
""")
p("rg53_for_index_order", """
sub main
  xs = [10, 20]
  for i, x in xs
    print(i, x)
""")
p("rg54_range_inclusive", """
sub main
  for i in 0..=3
    print(i)
""")
p("rg55_struct_field_default_expr", """
struct P
  x: Int = 1 + 2

sub main
  print(P().x)
""")
p("rg56_bool_int_cond", """
sub main
  n = 3
  if n
    print("nonzero")
""")
p("rg57_string_eq_vs_is", """
sub main
  a = "x"
  if a is "x"
    print(1)
""")
p("rg58_uppercase_local", """
sub main
  Total = 1
  print(Total)
""")
p("rg59_lowercase_struct", """
struct point
  x: Int

sub main
  p = point(x: 1)
  print(p.x)
""")
p("rg60_indent_after_parse_err", """
sub main
  x = (1 +
  print(x)
  y = 2
  print(y)
""")
p("rg61_two_errors", """
sub main
  a = undefined_one
  b = undefined_two
  print(a, b)
""")
p("rg62_else_without_if", """
sub main
  x = 1
  print(x)
  else
    print(2)
""")
p("rg63_self_method_missing_self_prefix", """
struct P
  x: Int

  fun double(?self) -> Int
    self.x * 2

  fun quad(?self) -> Int
    double() * 2

sub main
  print(P(x: 1).quad())
""")
p("rg64_return_bool_int", """
fun even(n: Int) -> Bool
  n % 2

sub main
  print(even(2))
""")
p("rg65_modulo_float", """
sub main
  print(7.5 % 2)
""")
p("rg66_print_format", """
sub main
  x = 1
  print("x = %d", x)
""")
p("rg67_readonly_param_assign", """
fun f(n: Int) -> Int
  n += 1
  n

sub main
  print(f(1))
""")
p("rg68_use_missing_module", """
use mathx

sub main
  print(mathx.f())
""")
p("rg69_import_python", """
import math

sub main
  print(1)
""")
p("rg70_bang_on_optional", """
fun f -> Int?
  1

sub main
  print(f()!)
""")
p("rg71_question_on_fallible", """
error E
  bad

fun f -> Int!
  1

fun g -> Int?
  f()?

sub main
  print(g() ?? 0)
""")
p("rg72_catch_on_optional", """
fun f -> Int?
  1

sub main
  print(f() catch 0)
""")
p("rg73_ooo_type_after_name_c", """
fun add(Int a, Int b) -> Int
  a + b

sub main
  print(add(1, 2))
""")
p("rg74_arrow_missing", """
fun add(a: Int, b: Int) Int
  a + b

sub main
  print(add(1, 2))
""")
p("rg75_struct_colon", """
struct P:
  x: Int

sub main
  print(P(x: 1).x)
""")
p("rg76_field_comma", """
struct P
  x: Int,
  y: Int

sub main
  print(P(x: 1, y: 2).x)
""")
p("rg77_while_do", """
sub main
  n = 0
  while n < 3 do
    n += 1
  print(n)
""")
p("rg78_then", """
sub main
  n = 0
  if n == 0 then
    print(n)
""")
p("rg79_end_keyword", """
sub main
  n = 0
  if n == 0
    print(n)
  end
""")
p("rg80_dup_field", """
struct P
  x: Int
  x: Int

sub main
  print(P(x: 1).x)
""")
p("rg81_missing_field_ctor", """
struct P
  x: Int
  y: Int

sub main
  p = P(x: 1)
  print(p.x)
""")
p("rg82_method_on_int", """
sub main
  x = 5
  print(x.abs())
""")
p("rg83_float_literal_trailing_dot", """
sub main
  x = 1.
  print(x)
""")
p("rg84_nested_fn", """
sub main
  fun inner(n: Int) -> Int
    n
  print(inner(1))
""")
p("rg85_str_to_int", """
sub main
  s = "12"
  print(Int(s))
""")
p("rg86_vec_index_owning", """
struct S
  v: Vec[Int]

sub main
  xs: Vec[S] = Vec()
  !xs.push(S(v: Vec()))
  y = xs[0]
  print(y.v.len)
""")
p("rg87_self_move_from_field", """
struct S
  v: Vec[Int]

struct T
  s: S

sub main
  t = T(s: S(v: Vec()))
  u = <t.s
  print(u.v.len)
""")
p("rg88_semicolon_two_stmts", """
sub main
  a = 1; b = 2
  print(a, b)
""")
p("rg89_bang_suffix_on_type_ret", """
fun f -> !Int
  1

sub main
  print(f())
""")
p("rg90_error_as_string", """
fun f(n: Int) -> Int!
  return "bad" if n < 0
  n

sub main
  print(f(1) catch 0)
""")
p("rg91_optional_param_default_none", """
fun f(n: Int? = none) -> Int
  n ?? 0

sub main
  print(f())
""")
p("rg92_closure_arrow_js", """
sub main
  f = (x) => x + 1
  print(f(1))
""")
p("rg93_closure_no_bars", """
sub main
  xs = [1, 2]
  f = |x| x + 1
  print(f(2))
""")
p("rg94_write_borrow_of_literal", """
sub bump(n: !Int)
  n += 1

sub main
  bump(!5)
""")
p("rg95_unused_param_ok_but_unused_for", """
sub main
  for i in 0..3
    print("x")
""")
p("rg96_int_overflow_literal", """
sub main
  x: U8 = 256
  print(x)
""")
p("rg97_string_single_char_index_compare", """
sub main
  s = "abc"
  if s[0] == "a"
    print(1)
""")
p("rg98_missing_colon_type", """
sub main
  x Int = 5
  print(x)
""")
p("rg99_capital_bool", """
sub main
  b: bool = true
  print(b)
""")
p("rg100_string_type_lower", """
fun f(s: string) -> Int
  s.len

sub main
  print(f("a"))
""")
p("rg101_str_type", """
fun f(s: str) -> Int
  s.len

sub main
  print(f("a"))
""")
p("rg102_int_type_lower", """
fun f(n: int) -> int
  n

sub main
  print(f(1))
""")
p("rg103_float_f64", """
sub main
  x: f64 = 1.0
  print(x)
""")
p("rg104_return_multiple", """
fun f -> Int
  return 1, 2

sub main
  print(f())
""")
p("rg105_move_then_reassign_ok", """
struct S
  v: Vec[Int]

sub main
  s = S(v: Vec())
  t = <s
  print(s.v.len, t.v.len)
""")
p("rg106_borrow_outlives", """
struct S
  n: Int

sub main
  r = ?S(n: 1)
  print(r.n)
""")
p("rg107_catch_without_value", """
error E
  bad

fun f -> Int!
  return E.bad

sub main
  x = f() catch
  print(x)
""")
p("rg108_elseif_single_word", """
sub main
  x = 3
  if x > 5
    print("big")
  elsif x > 1
    print("mid")
""")
p("rg109_bang_prefix_write_on_field_call", """
struct C
  v: Vec[Int]

sub main
  c = C(v: Vec())
  c.v.push(1)
  print(c.v.len)
""")
p("rg110_this", """
struct P
  x: Int

  fun get(?self) -> Int
    this.x

sub main
  print(P(x: 1).get())
""")
p("rg111_return_type_sub_arrow_void", """
sub f -> ()
  print(1)

sub main
  f()
""")
p("rg112_if_paren_cond_colon", """
sub main
  x = 1
  if (x == 1) {
    print(x)
  }
""")
p("rg113_neg_unsigned", """
sub main
  x: U8 = -1
  print(x)
""")
p("rg114_mutable_param_write_through_read", """
sub set(n: ?Int)
  n = 5

sub main
  x = 1
  set(?x)
  print(x)
""")
p("rg115_equal_eq_string_assign", """
sub main
  name == "x"
  print(name)
""")

os.makedirs("probes", exist_ok=True)
for k, v in P.items():
    open(f"probes/{k}.rig", "w").write(v)
print(len(P))
