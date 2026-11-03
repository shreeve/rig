# Idiom and beauty review: the ray tracer (2026-10-29)

`compare/rig/ray-tracing/ray.rig` and `ray-dyn.rig`, read beside the book (Shirley, *Ray Tracing
in One Weekend*). The Rust was looked at for shape only; nothing here comes from it. `rig` is the
baseline build `81a1ef48`.

**How each change was probed.** Each file was copied to a temp dir, set to 200 x 133 at 10
samples (depth 50), changed there, built `--release=fast`, and its PPM compared with the
current port's (sha `8b32a836…`): every change below is byte-identical. The final versions were
also compared at the full 600 x 400, 50 samples (sha `dba01470…`, identical for the current
ray.rig, ray-dyn.rig, and every variant), and run clean under `RIG_SANITIZE=1 rig run` at
40 x 27, 2 samples. Times: fastest of 7, interleaved, through `tools/low`, Mac load 18 to 25, so
rough. Changed files: `reviews/ray-idiom-probes/single/ray.rig` (changes 2 to 7 in one file) and
`reviews/ray-idiom-probes/shared/{weekend,ray,ray-dyn}.rig` (change 1 on top of them). Nothing
under `compare/` was edited.

The port is already good Rig. `Hit` holding `mat: ?Material` with `from @` is the book's
`shared_ptr` done as a lend the compiler records; `scatter` returning a `Scatter?` and
`?? return` in `ray_color` read better than the book's bool and out-parameters; `ray_color` as a
loop, `normal: outward if front else -outward`, and the per-row seeds under `par.map` are the
right forms. The findings are about the scene, the camera, and sharing code.

## Ranked

1. **Share the book in one module, `weekend.rig`; `ray.rig` and `ray-dyn.rig` keep only their
   `World` and a two-line `main`.** (probed: identical; ray 3.24 s against 3.28 s, ray-dyn 4.97 s
   against 4.91 s, once `ray_color` is marked `inline`, see the gap)
2. **The scene builds with `!world.add(center, radius, mat)`, the book's `world.add`.** (probed)
3. **Enum variants by shorthand: `.lambertian(albedo: …)` where the type is known.** (probed)
4. **The scene's material is an `if` value, not a default overwritten.** (probed)
5. **`Camera.new` is called with keyword arguments, one a line.** (probed)
6. **`BLACK` and `WHITE` constants for the six `vec(0, 0, 0)` and `vec(1, 1, 1)`.** (probed)
7. **Header in house style; `random_unit_vector` returns `unit(p)`.** (probed)

Together, 2 to 7 take ray.rig from 2,681 tokens to 2,629 and leave no line over 100 columns (it
had six, the longest 131). It gains 21 lines, 16 of them the camera's keyword lists.

## 1. One module for the book, two worlds (probed)

The two files differ only in `World` (its list's type and its loop) and the four `^` of the
scene. `ray-dyn.rig` repeats 240 lines to show 10. With the book in `weekend.rig`:

```
# ray.rig                                      # ray-dyn.rig
use weekend                                    use weekend

obj World: weekend.Hittable                    obj World: weekend.Hittable
  objects: List[weekend.Sphere]                  objects: List[^{weekend.Hittable + Syncs}] = List()

  fun hit(?@, r: weekend.Ray, lo: Float,         fun hit(?@, r: weekend.Ray, lo: Float,
      hi: Float) -> weekend.Hit? from @              hi: Float) -> weekend.Hit? from @
    best: weekend.Hit? = none                      best: weekend.Hit? = none
    closest = hi                                   closest = hi
    for i in 0..@objects.len   # R1, R2            for o in ?@objects
      o = ?@objects[i]                               if o.hit(r, lo, closest) as h
      if ?o.hit(r, lo, closest) as h                   closest = h.t
        closest = h.t                                  best = h
        best = h                                   best
    best
                                               sub main()
sub main()                                       world = World()
  weekend.render(World(objects: weekend.scene()))  for s in weekend.scene()
                                                   !world.objects.push(^s)
                                                 weekend.render(?world)
```
(The `hit` signature is one line in the files; it is folded here to fit.)

In `weekend.rig`, `scene()` returns the cover's `List[Sphere]`, built with a free
`add(!spheres, center, radius, mat)`, and the old `main` becomes
`pub sub render[W: Hittable + Syncs](world: ?W)`, the newer book's `camera.render(world)`;
`ray_color` and the row function take `[W: Hittable]`. What `pub` it needs: `Ray`, `Hit` and
its `t`, `api Hittable`, `Sphere` and its `hit`, `scene`, `render`. Fields stay private, as
`Sphere` is made inside the module.

Why: the comparison becomes a controlled one, the world and nothing else, and each `main` file
is about 15 lines a reader takes in at once. It also adds forms the library otherwise lacks: a
module of the program's own, `pub`, a generic bound with an API and `Syncs`, and `^s` boxing a
copy. Lines: 208 + 14 + 16 = 238 for both programs, against 199 + 198 = 397 now. The cost is
`weekend.` before four names in each `World`.

**The marker.** Without it ray-dyn is 5% slower (5.23 s against 4.91 s, fastest of 7; ray
unchanged). The compiler inlines a small non-generic function by itself but no function with
compile-time type parameters (INTERNALS, "Inlining"), so the generic `ray_color` became a call.
`inline fun ray_color[W: Hittable](…)` restores it (4.97 s). That is the one marker in the
port, and the README says why.

## 2. `world.add`, as the book writes it (probed)

```
before:
  !world.objects.push(Sphere(center: vec(0.0, 1.0, 0.0), radius: 1.0, mat: Material.dielectric(index: 1.5)))
after:
  sub add(!@, center: Vec3, radius: Float, mat: Material)         # in World
    !@objects.push(Sphere(center: center, radius: radius, mat: mat))

  !world.add(vec(0.0, 1.0, 0.0), 1.0, .dielectric(index: 1.5))
```
Why: four of the five pushes ran 108 to 131 columns. The book's reader recognises `world.add(...)`.
With change 1, `add` becomes a free function in `weekend.rig` over `!List[Sphere]`.

## 3. Variant shorthand (probed)

`mat: .lambertian(albedo: vec(0.5, 0.5, 0.5))` wherever the parameter, field, or binding names
`Material`. Why: the type is already said; `Material.` eight times is noise. The shorthand is
accepted in an argument, a field of a constructor, and the branches of a typed `if`.

## 4. The material as a value (probed)

```
before:                                          after:
  mat = Material.dielectric(index: 1.5)            mat: Material = if choose < 0.8
  if choose < 0.8                                    .lambertian(albedo: random_vec(!rng, 0.0, 1.0) * …)
    mat = Material.lambertian(albedo: …)           else if choose < 0.95
  else if choose < 0.95                              .metal(albedo: random_vec(!rng, 0.5, 1.0), fuzz: …)
    mat = Material.metal(albedo: …, fuzz: …)       else
                                                     .dielectric(index: 1.5)
```
Why: no value made only to be overwritten, and the three cases read in the book's order,
diffuse, metal, glass, with their 80/15/5 thresholds.

## 5. The camera by name (probed)

```
before:
  cam = Camera.new(vec(13.0, 2.0, 3.0), vec(0.0, 0.0, 0.0), vec(0.0, 1.0, 0.0), 20.0, Float(WIDTH) / Float(HEIGHT), 0.1, 10.0)
after:
  cam = Camera.new(
    from: vec(13.0, 2.0, 3.0),
    at: vec(0.0, 0.0, 0.0),
    vup: vec(0.0, 1.0, 0.0),
    vfov: 20.0,
    aspect: Float(WIDTH) / Float(HEIGHT),
    aperture: 0.1,
    focus: 10.0,
  )
```
and the 123-column `fun new(...)` signature broken the same way. Why: seven positional
numbers are unreadable. These are the book's camera settings (`lookfrom`, `lookat`, `vup`,
`vfov`, `defocus`, `focus_dist`), now named where they are set.

## 6. `BLACK` and `WHITE` (probed)

`BLACK = Vec3([0.0, 0.0, 0.0, 0.0])`, `WHITE = Vec3([1.0, 1.0, 1.0, 0.0])`, module constants (a
vector of constants may be one). Used in `sky`, glass's attenuation, the start and two ends of
`ray_color`, and each pixel's sum. Why: `?? return BLACK` says what the absorbed ray gives.
The camera's `at` stays `vec(0.0, 0.0, 0.0)`, since it is a point and not a color.

## 7. Small (probed)

- Header: what it is, then `# Ports Peter Shirley's book (raytracing.github.io), written from
  its text.` last, per house style.
- `random_unit_vector`: `return unit(p) if …` for `p * (1.0 / math.sqrt(len2))`; the same
  operations, the same image.

## Kept as they are

- `Scatter?` from `scatter`: right until several results may form an optional.
- `new r = r` in `ray_color`: the documented way to change a parameter.
- `dot` by lanes and `* (1.0 / x)`: G14, no lane sum and no `/` on a float vector.
- `near_zero` by three `math.abs`: `math.abs` takes no vector, and a mask form is no clearer.
- `Row` with its seed: `par.map` gives no index (G10). Seeding by `SEED + y` would drop the
  object but changes the image, so it is not offered.
- The order of declarations follows the book closely enough (vectors, randoms, ray, hit,
  material, sphere, world, camera, color, scene, output); moving `Material` after `World` would
  match the chapters exactly. Not probed; not worth a change by itself.

## Gaps

- **G-inline (new, small):** the inliner never inlines a function with compile-time type
  parameters, so moving `ray_color` behind `[W: Hittable]` cost ray-dyn 5% until it was marked
  `inline`. Documented behaviour, but it makes a generic helper slower than the same helper
  written for one type, which a reference program should not have to know. A question for the
  owner: should the size rule apply to each generic instance?
- No new correctness gaps; R1 and R2 are the known ones the `World` loop works around.
