# The owner's Ruby, said in Rig

Ten snippets of the owner's production Ruby, each written as idiomatic
Rig. The point is the idioms, not the web framework, so library calls
(`req.string`, `db.exec`, `Http.invalid`) are stand-ins.

Each Rig form is marked:

- **[today]**: Rig accepts it now.
- **[T]**: `if c then x` on one line (proposed).
- **[U]**: `unless c` = `if not c` (proposed; same node).
- **[M]**: `match` on strings and literals (Trig NEEDS.md 4).
- **[E]**: errors that carry data (Rig roadmap, IDEAS 1.4).
- **[Q]**: `x ??= e`, assign when `none` (proposed).
- **[H]**: multi-line string literals (proposed).
- **[D]**: a type for "one of several shapes": an enum with payloads
  (Rig has enums; payload ergonomics to check).

## The one lesson that covers most of it

Ruby chains `&&`, `||`, `and`, `or` and assignments because `nil` and
`false` are falsy. Rig has no truthiness, but it has a typed form for
every one of those uses, and each one reads the same way:

| Ruby (truthiness) | Rig (types) | Status |
|---|---|---|
| `(u = user) && u.parent? && u` | `if user() as u and u.is_parent()` | [today] |
| `x \|\| default` | `x ?? default` | [today] |
| `x or raise` | `x ?? return Err` / `f()!` | [today] |
| `expr rescue fallback` | `expr catch fallback` | [today] |
| `@memo \|\|= compute` | `self.memo ??= compute()` | [Q] |
| `x unless c` | `x if not c`, or `x unless c` | [today], [U] |
| `foo && begin … end` | `if foo as f` + block | [today] |
| `case s when 'a' then …` | `match s` with `"a" => …` | [M] |

`if a as x and test(x) and b as y` is exactly Ruby's
`(x = a) && test(x) && (y = b)`: it binds, tests, and short-circuits in
order. The difference is that the names are typed and live only inside
the `if`.

## 1. Memoized guards: `parent!`, `admin!`

```ruby
def parent!
  @session_parent ||= begin
    (user = user!) &&
    (user.parent?) &&
    user or signout!
  end
end
```

```rig
# The current user, who must be a parent.
fun parent(!self) -> User!
  if self.session_parent as p then return p                       # [T]
  if self.user() as u and u.is_parent()                           # [today]
    self.session_parent = u
    return u
  self.signout()

# The signed-in admin.
fun admin(!self) -> User!
  if self.session_admin as a then return a                        # [T]
  if self.session.get("admin_id") as id and User.find(id) as a and a.is_admin()
    self.session_admin = a
    return a
  self.signout()
```

With [Q], each is one line plus a helper:
`self.session_parent ??= self.find_parent() ?? return self.signout()`.
That is shorter, but the block form above is the one a reader follows.

## 2. A value chosen by a string: vaccine manufacturers

```rig
manufacturers = match slug                                        # [M]
  "adc"  => ["AstraZeneca", "Janssen", "Moderna",                     "Pfizer"]
  "pure" => ["AstraZeneca", "Janssen", "Moderna", "Novavax", "Other", "Pfizer", "Sinovac-CoronaVac", "Zifivax"]
  _      => [               "Janssen", "Moderna",                     "Pfizer"]
```

Ruby's `when … then` arm is Rig's `pattern => value`. The column
alignment is worth keeping: Rig's spacing rules should allow padding
inside a list literal (to check).

## 3. A request handler: signup

```rig
# public: create a new account
fun signup(!app, req: ?Request) -> Response!
  (!app.session).destroy()

  # args
  slug = req.string("sponsor")
  fnam = req.name("first_name")
  lnam = req.name("last_name")
  mail = req.email("email")
  phon = req.phone("phone")

  # validate
  errs = Map[Static, Static]()
  !errs.put("first_name", "Enter a first name")   unless fnam     # [U]
  !errs.put("last_name",  "Enter a last name")    unless lnam
  !errs.put("email",      "Enter a valid email")  unless mail
  !errs.put("phone",      "Enter a phone number") unless phon
  if errs.len > 0 then return Http.invalid(errs)                  # [T] [E]

  # decipher codes
  if slug as s and s.lower().after("code-") as code then slug = decrypt(code)
  role = none
  if slug == none and SponsorEmails.locate(mail) as found
    slug = found.sponsor
    role = found.role

  # put unmapped crossover users into the retail sponsor
  if slug == none and app.client == "crossover" then slug = "retail"

  # create the user
  user = User.create(
    sponsor:   slug ?? app.client,
    role:      role ?? "user",
    first_name: fnam,
    last_name:  lnam,
    email:      mail,
    phone:      phon,
    status:     "signup",
    status_at:  Time.now(),
  ) catch return Http.invalid(email: "Please try another email address")

  # send a signup email
  subject = app.custom("emails/signup")
  link = app.dynamic_link(String("signin/", app.signin_code(?user)))
  code = app.access_code(?user, ?user)
  app.send_email(mail, subject, render("signup", link: link, code: code))
  Http.json()
```

Notes:

- **`unless fnam`** reads as Ruby does. Under the one-node rule it is
  `(if (not …) …)`, the same node as `if fnam == none`. A field that
  failed to read is `none`, so the test is on an optional.
- **The regex `\Acode-([a-z\d]+)\z`** becomes `s.after("code-")`. Rig
  has no regex today; a regex library would be a std module, not syntax.
- **`slug, role = locate(mail) if !slug`** returns two values. Rig has no
  tuple binding yet, so `found.sponsor` / `found.role` stand in.
- **`rescue begin … end`** is `catch return …`, which Rig has today.

## 4. Do something only if present, and survive a failure

```rig
# upload the photo
if foto as f
  (!whom).upload_photo(f) catch |e|
    debug("user photo upload failed")
    toast("Profile created but image upload failed")
```

`foto && begin … rescue … end` is `if foto as f` (present) plus
`catch |e|` (failed): two concepts, each with its own keyword.

## 5. Nested ternaries: fake associations

```rig
match spon                                                        # [M]
  "crossover"
    groups = ["crossover", "visa", "microsoft", "hp", "adc", "pure", "retail"]
    spon = pick(groups, grup, spon)
  "powerme", "doterra"
    spon = pick(["doterra", "powerme"], grup, spon)

# Every group when `grup` is missing or "all", `grup` when it is one of
# them, and `spon` otherwise.
fun pick(groups: List[Static], grup: Static?, spon: Sponsors) -> Sponsors   # [D]
  if grup == none or grup == "all" then return Sponsors.all(groups)
  if grup in groups then return Sponsors.one(grup)
  spon
```

In the Ruby, `spon` is sometimes a list and sometimes a string. A typed
language has to say that, so `Sponsors` is an enum with two shapes
([D]). The duplicated ternary chain becomes one named function.

## 6. Try, fall back, continue: Stripe

```rig
fun stripe(data: ?Map[Static, Value], base: Api) -> List[Charge]
  if not HUSH_STRIPE then debug("stripe called", data)            # [T]
  cents = data.decimal("amount") ?? 0
  charge = if base == .payment_intent and cents < 50
    event("comped charge", data)
    Charge(status: "succeeded", paid: true)
  else
    base.create(data, key: custom("stripe.secret")) catch |e|
      event("stripe failed", e)
      Charge(status: "failure")
  stripe_list(charge)
```

`begin … rescue => e … end` around the whole body becomes `catch |e|`
on the one call that can fail, so the failure is attached where it
happens. The `if`/`else` block is the value of `charge` [today].

## 7. A chained condition with assignments: handle failure

```ruby
(cred = meta['credit']).present? && ((cred = cred.decimal) != 0) and user.add_credit(cred)
```

```rig
if stat == "failure"
  if meta.get("credit") as c and c.decimal() as d and d != 0 then (!user).add_credit(d)   # [T]
  return Purchase.failed                                          # [E]
```

This is the clearest case for `if … as … and`: every binding and test
in Ruby's chain maps to one, left to right, with no reassigning `cred`
from a string to a number.

## 8. Run SQL and require one row: update transaction status

```rig
UPDATE_STATUS = """                                               # [H]
  update transactions
  set    date=?, status=?, meta=?
  where  id=? and status=?
"""

if db.exec(UPDATE_STATUS, time, stat, meta.json(), seed.id, seed.status)! != 1 then return Db.conflict   # [T] [E]
Transaction.where(group_id: seed.id).update_all(date: time, status: stat)
```

`… == 1 or raise` becomes `if … != 1 then return …`: the same test, the
same exit, with the failure named.

## 9. String processing: unbrace

```rig
# "a{b,c}d e" -> ["abd", "acd", "e"]
fun unbrace(s: ?String) -> List[String]
  words = s.trim().words()
  if not s.contains("{") then return words                        # [T]
  out = List[String]()
  for w in words
    if w.split3("{", "}") as (head, body, tail)
      for stem in body.split(",")
        !out.push(String(head, stem, tail))
    else
      !out.push(+w)
  out
```

`list.inject([]) … end if include?('{')` (a fold with a trailing
condition) is clearer as a guard plus a plain loop. `split3` is a
stand-in for the regex.

## 10. A message by key, with a default: snack

```rig
fun snack(!self, key: Static, code: Int = 400)!
  text = match key                                                # [M]
    "card" => "Order a spend card to transfer funds"
    "done" => "Request has already been processed"
    "fund" => "Primary account holder needs a bank account or card"
    "cant" => "Unable to remove funding source"
    _      => key if key.has(" ") else "Oops... there was a problem"
  self.halt(code, json(error: (snackbar: text)))
```

`{…}[obj] || default` is a `match` with a `_` arm. Ruby's "a String or a
Symbol" in one parameter becomes a test on the value itself here; a
cleaner design would be two functions, or an enum.

## What this code asks of Rig

1. **Already there, and the answer to most of it:** `if a as x and …`
   chains, `??`, `catch` and `catch |e|`, `!`/`?` propagation, `if`
   blocks as values, and named arguments.
2. **Proposed, and used throughout this code:**
   - [T] `if c then x`;
   - [M] `match` on strings;
   - [E] errors with data.
3. **Proposed, smaller:**
   - [U] `unless`, as `if not` (one node);
   - [Q] `??=`;
   - [H] multi-line strings;
   - tuple returns;
   - [D] enum payload ergonomics.
4. **Not syntax:** regex and a web framework belong in libraries.
5. **What does not carry over: truthiness.** Ruby's
   `a && b && c or d` works because anything can be false. In Rig a
   condition is a `Bool`, and presence is `as`. That is the one habit
   to unlearn, and `if x as v` is what replaces it.
