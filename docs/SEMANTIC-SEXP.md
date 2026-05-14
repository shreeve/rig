# Rig Semantic S-Expression IR

The semantic IR is what M2 (ownership checker) and M3 (Zig emitter) consume. It comes from `src/normalize.zig`, which walks the raw parser output and applies the rules below.

The IR's design rule:

> Visible effects in the source must be visible Tags in the IR. Cosmetic head-renames clean up parser noise. No type info is added at this stage; M2/M3 do that.

## Cheat sheet — raw → normalized

| Raw S-expr from parser          | Normalized                          | Note                                           |
|---------------------------------|-------------------------------------|------------------------------------------------|
| `(= target expr)`               | `(set target _ expr)`               | "set" is neutral; M2 disambiguates bind/rebind. 4-child shape with type slot at items[2] (`_` = no annotation) |
| `(+= target expr)` etc.         | `(set_op += target expr)`           | compound assignment (op as child)              |
| `(move_assign target expr)`     | `(set target _ (move expr))`        | `<-` is sugar for `target = <expr`             |
| `(fixed_bind name expr)`        | `(fixed_bind name _ expr)`          | unified 4-child shape                          |
| `(shadow name expr)`            | `(shadow name _ expr)`              | unified 4-child shape                          |
| `(typed_assign name type expr)` | `(set name type expr)`              | typed `=` folds into `set` with type slot      |
| `(typed_fixed name type expr)`  | `(fixed_bind name type expr)`       | typed `=!` folds into `fixed_bind` with type slot |
| `(extern_var name type)`        | `(extern_decl _ name type)`         | extern variable (kind = `_` for var)           |
| `(extern_const name type)`      | `(extern_decl fixed name type)`     | extern const (kind = `fixed`)                  |
| `(. obj name)`                  | `(member obj name)`                 | cosmetic                                       |
| `(pair name expr)`              | `(kwarg name expr)`                 | named call args / constructor sugar            |
| `(? T)`                         | `(optional T)`                      | optional type                                  |
| `(for x _ (read xs) body)`      | `(for read x xs body)`         | SPEC §"Semantic IR Nodes": `(for mode binding collection body)` — mode is at child position 1, not a head Tag |
| `(for x _ (write xs) body)`     | `(for write x xs body)`        | mode is one of `read`, `write`, `move`, or `_` (nil) for default iteration |
| `(for x _ (move xs) body)`      | `(for move x xs body)`         |                                                |
| `(for x _ source body)`         | `(for _ x source body)`        | nil mode = no ownership effect on source       |
| `(for_ptr ...)`                 | `(for_ptr ...)`                | unchanged (Zag-style pointer iteration; has an extra binding for the pointer) |

Everything else (calls, literals, control flow, types) passes through unchanged for M1; M2 and M3 may further normalize.

## Full IR shape

### Module structure

```
(module ...top-level-decls...)
```

### Declarations

```
(fun name params returns body)
(sub name params body)
(lambda params returns body)
(type name typeexpr)             ; type alias
(generic_type name params? members)
(struct name members)
(enum   name members)
(errors name members)
(opaque name)
(use name)
(test desc body)
(extern_decl <kind> name type)   ; kind = _ (var) | fixed (const)
(zig string)                     ; raw Zig escape hatch (M2: unsafe)
(labeled name stmt)

; decoration wrappers (chainable)
(pub child) (extern child) (export child) (packed child) (callconv name child)
```

### Bindings

All binding forms (except `set_op`) share a uniform 4-child shape with
a type slot at items[2] — `_` (nil) when there's no annotation.

```
(set        name type-or-_ expr)   ; from `=`   (M2 disambiguates bind/rebind)
(fixed_bind name type-or-_ expr)   ; from `=!`
(shadow     name type-or-_ expr)   ; from `new x = expr`
(set_op op-tag target expr)        ; from `+=`, `-=`, `*=`, `/=`  (no type slot)
(drop name)                        ; statement-position `-name`
```

The typed surface forms (`x: Int = 5`, `x: Int =! 5`) collapse into
`set` and `fixed_bind` with the type slot populated — there's no
separate `typed_set` / `typed_fixed` head.

### Ownership wrappers (expression position)

```
(move expr)  ; <x   transfer ownership in
(read expr)  ; ?x   read borrow
(write expr) ; !x   write borrow
(clone expr) ; +x   clone
(share expr) ; *x   shared strong
(weak expr)  ; ~x   weak reference
(pin expr)   ; @x   pinned address
(raw expr)   ; %x   raw / unsafe access
```

### Control flow

```
(if cond then else?)
(while cond body else?)
(while cond cont body else?)     ; `while c : cont body` form
(for     mode binding source body else?)   ; mode = read | write | move | _ (nil = no mode)
(for_ptr binding ptr_binding? source body else?)
(match scrutinee arms...)
(arm pattern binding? body)
(range_pattern lo hi)
(enum_pattern name)
(block stmts...)
(return value? if?)
(break label? value? if?)
(continue label? if?)
(defer body)
(errdefer body)
(try expr)                       ; prefix `try expr`
(try_block body catch_block?)    ; value-yielding try
(catch_block name body)
(catch expr name? body)          ; postfix `expr catch ...`
(propagate expr)                 ; suffix `expr?`
(ternary cond then else)
```

### Calls and access

```
(call fn args...)                ; positional args, kwarg interspersed as (kwarg n v)
(kwarg name value)               ; named arg
(member obj name)                ; obj.name
(deref expr)                     ; obj.*
(index expr idx)                 ; obj[idx]
(record TypeName members...)     ; only from `Type{...}` braced form (Zag-record)
(anon_init members...)           ; .{ ... }
(array elems...)                 ; [a, b, c]
(builtin name args...)           ; @name(args)
(addr_of expr)                   ; &x
(enum_lit name)                  ; .strict
```

### Literals

```
(null) (true) (false) (undefined) (unreachable)
INTEGER REAL STRING_SQ STRING_DQ                ; raw parser src refs
```

### Types

```
(optional T)                     ; from `?T`
(error_union T)                  ; from `!T`
(ptr T) (const_ptr T) (volatile_ptr T)
(slice T) (sentinel_slice S T)
(array_type N T)
(many_ptr T) (sentinel_ptr S T)
(fn_type params ret)
(typed name type)                ; field decl shape
(default name type expr)         ; field default
(aligned name type alignexpr)
(pre_param name type)            ; pre-time parameter
```

### Operators

```
(+ a b) (- a b) (* a b) (/ a b) (% a b) (** a b)
(== a b) (!= a b) (< a b) (> a b) (<= a b) (>= a b)
(&& a b) (|| a b) (& a b) (| a b) (^ a b) (<< a b) (>> a b)
(|> a b)                         ; pipe
(.. a b)                         ; range
(neg x) (not x)                  ; unary
(?? a b)                         ; nullish coalesce
```

### Compile-time

```
(pre expr)                       ; `pre expr` modifier (was Zag `comptime`)
(pre_block body)                 ; `pre INDENT body OUTDENT`
(pre_param name type)            ; member-position `pre name : type`
```

### Misc

```
(inline expr)                    ; Zig-style inline call (kept for V1)
```

## Notes for M2 (ownership checker)

- `set` may be either a fresh bind or a rebind — the checker decides per scope.
- `shadow` is always a fresh binding that hides the previous one.
- `fixed_bind` and `typed_fixed` are always fresh and immutable.
- `(move x)`, `(read x)`, `(write x)`, `(drop x)` are the primary borrow-check operations.
- `(member obj name)` should be treated as a borrow of the path; the checker preserves field paths in diagnostics.
- `(propagate x)` requires the enclosing function to have an `error_union` return type — this is a **semantic** check at M2 boundary or M3 emit.
- Raw escape hatches (`(raw x)`, `(zig string)`, `(builtin name ...)` for unchecked builtins, `(extern ...)`, `(volatile_ptr ...)`) bypass ownership checking; the checker may emit a warning class but should not block.

## Notes for M3 (Zig emitter)

- `(set x e)` lowers to `var x = e;` (first occurrence) or `x = e;` (rebind), per M2's classification.
- `(fixed_bind x e)` lowers to `const x = e;`.
- `(propagate e)` lowers to Zig `try e`.
- `(try_block body (catch_block err catch_body))` lowers to a Zig block expression, possibly via `blk: { ... }` if value-yielding.
- `(for read x xs body)` lowers to `for (xs) |x| { ... }` (Zig's iteration over a const ref) — borrow semantics enforced by the checker, not the emitted Zig.
- `(for move x xs body)` lowers to a consuming iteration (Zig `for (&xs) |x| {...}` with consumption is a future concern; V1 may model this with explicit element-by-element move + `xs.deinit()`).
- `(record T (kwarg name v) ...)` and `(call T (kwarg name v) ...)` both lower to `T{ .name = v }` Zig struct literal when the callee is a known type.
