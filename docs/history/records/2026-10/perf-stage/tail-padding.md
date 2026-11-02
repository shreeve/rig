# Reach of "a Map's value in its key's tail padding" (2026-11-01)

Measured by reading layouts, not built. Parked until a round on the Map's
entry layout (docs/internals/backlog.md).

From the census in Trig research 22 (ts-pattern, 1 checker) and the key objects in src/checker/types.rig. Room is the entry array's capacity; the saving is in room, since all of these maps are at full size at peak RSS.

| Map | key layout | entry now | with value in key padding | room | saved |
|---|---|---|---|---:|---:|
| instantiations `InstantiationKey -> TypeId` | owner U64 + CacheKey 16 = 24, no padding | 32 | 32 | 524,288 | 0 |
| relations, hashed caches `CacheKey -> U32` | 16, no padding | 24 | 24 | | 0 |
| `CachedSignatureKey -> SigId` | sig U32 + 4 pad + CacheKey 16 = 24 | 32 | 24 | 32,768 | 256 KiB |
| `UnionOfUnionKey -> U32` | 2 TypeId + enum + CacheKey = 25 → 32 | 40 | 32 | 8,192 | 64 KiB |
| `InferenceKey -> I32` | 14 → 16 (2 pad) | 20 | 20 (I32 does not fit) | | 0 |
| `U32 -> Int`, `U32 -> U32`, `Sym -> MappedSymbolLinks` | no key padding | | | | 0 |

**Alone: about 0.3 MiB on ts-pattern (0.13% of peak RSS), less on zod3.** The instantiation key has no padding: its 4 wasted bytes are the entry's, after the U32 value.

**With the owner narrowed to a U32 in Trig** (a type, root or alias id is at most 27 bits plus a 2-bit tag): the key becomes U32 + 4 pad + CacheKey = 24, the value fits the padding, and the entry drops from 32 to 24 bytes. Room saved: 4 MiB on ts-pattern (1.7% of 235 MB), 0.5 MiB on zod3 (0.7%). Unlike the packing measured slower (the owner folded into the CacheKey's 128 bits), this keeps the key's fields plain, with no repacking on lookup. Narrowing alone, without the Rig change, saves nothing: the 24-byte key plus a U32 value still pads to 32.

**Soundness note for any design:** a struct assignment may copy a key's padding bytes, so the value cannot live in the padding of a key the program can hold or assign as a whole. The entry would have to lay out the key's fields and the value side by side, and hand out keys by value or field by field.
