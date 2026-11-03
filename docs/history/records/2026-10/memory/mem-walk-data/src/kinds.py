# kinds.py PROJ: Trig's live memory at the end of check by kind, in the tsrs census's kinds
# (mem-census/tsrs.md), beside tsrs shipped and Go mode. Trig: Tables resident (plain build,
# mincore) + heap owners (heap-profile build); the map indexes (u64) split by the sites run.
import sys, re, collections
M = 1 << 20; p = sys.argv[1]
TS = {  # tsrs live MiB at check end (mem-census/tsrs.md), shipped / go
 "empty": {"1":(2.97,5.71),"2":(0.02,0.02),"3":(0.57,1.20),"4":(0.34,0.66),"5":(0.01,0.01),"6":(0,0),"7":(0.24,0.24),"8":(2.91,2.91),"9":(0.08,0.03),"10a":(0,0),"10b":(0,0),"10c":(0.05,0.13),"10d":(0,0),"10e":(0,0),"10g":(0.22,0.22)},
 "zod3": {"1":(4.39,9.01),"2":(0.14,0.14),"3":(2.89,6.35),"4":(3.30,7.87),"5":(6.18,5.96),"6":(1.65,1.65),"7":(2.73,4.32),"8":(3.41,3.41),"9":(4.77,4.83),"10a":(1.42,1.52),"10b":(0.08,0.08),"10c":(0.27,0.42),"10d":(0.11,0.11),"10e":(0.04,0.04),"10g":(0.39,0.38)},
 "ts-pattern": {"1":(4.02,9.63),"2":(0.93,0.93),"3":(14.97,29.89),"4":(11.61,32.49),"5":(35.38,34.05),"6":(7.79,7.78),"7":(11.98,20.41),"8":(3.46,3.46),"9":(37.27,36.46),"10a":(8.22,12.10),"10b":(1.95,1.95),"10c":(0.23,0.36),"10d":(0.35,0.33),"10e":(0.09,0.09),"10g":(0.41,0.41)}}
NAMES = {"1":"AST nodes","2":"identifiers and text","3":"symbols","4":"symbol tables and members","5":"types","6":"signatures",
 "7":"links and side tables","8":"source and lib file text","9":"lists, caches and maps","9b":"binder lists by node (Trig only)","10a":"mappers",
 "10b":"inference","10c":"flow nodes","10d":"diagnostics","10e":"node builder","10g":"program, config, other"}
TYPES = set("""Type StructuredType StructuredExtra TypeParameter ConditionalType TypeReference UnionOrIntersectionType
UnionOrIntersectionExtra MappedType LiteralType IndexedAccessType InterfaceType SubstitutionType TupleType IndexType
EvolvingArrayType InstantiationExpressionType StringMappingType UniqueESSymbolType IntrinsicType TemplateLiteralType
ReverseMappedType IndexInfo TypeAlias TypePredicate ConditionalRoot""".split())
k = collections.defaultdict(float)
for i, l in enumerate(open(f"data/plain/{p}/check.tables")):
    res, size, n, ptr, nb, name = l.split(None, 5); res = int(res) / M; n_ = name.strip().split(".")[-1]
    if n_ in TYPES: k["5"] += res
    elif n_ in ("Signature", "SignatureExtra", "CompositeSignature"): k["6"] += res
    elif n_ in ("CheckerSymbol", "SymbolData"): k["3"] += res
    elif n_.endswith("Links") or n_ == "ValueSymbolExtra": k["7"] += res
    elif n_ == "TypeMapper": k["10a"] += res
    elif n_ == "u32" and i == 37: k["4"] += res          # sym_lists: member lists
    else: k["9"] += res                                 # type/sig/info lists, NodeRef, ElementInfo, Loc
def owners(stage):
    d = {}
    for l in open(f"data/prof/{p}/{stage}.owners"):
        live, b, m, name = l.split(None, 3); d[name.strip()] = int(live) / M
    return d
chk, bnd, lod = owners("check"), owners("bind"), owners("load")
# u64 blocks of 0.15 MiB or more at single-block cache sites are cache indexes; the rest member/symbol-table indexes
cache_idx = 0.0; links_idx = 0.0
import os
sites = open(f"mac-sites/r/{p}/err").read() if os.path.exists(f"mac-sites/r/{p}/err") else ""
for l in sites.split("\n#")[1:]:
    m = re.match(r"\d+: ([\d.]+) MiB, [\d.]+%, (\d+) blocks of u64,", l)
    if m and float(m.group(1)) >= 0.15 and m.group(2) == "1":
        if "resolve_mapped_type_members" in l: links_idx += float(m.group(1))
        elif "declare_symbol" in l: pass
        else: cache_idx += float(m.group(1))
for name, v in chk.items():
    if re.match(r"ast\.(NodeRec|ListRec|Node$|File$|Pragma)|rig\.runtime\.ListOf\(ast\.Node|Ordered\(rig\.runtime\.String,ast\.File\)|parser\.", name): k["1"] += v
    elif name in ("u8",) or name.startswith("ast.TextRec"): k["2"] += v
    elif name == "ast.SymbolRec": k["3"] += v
    elif name.startswith("__rig_std_prelude.Map(u32,u32)") or name.startswith("rig.ordered.Ordered(u32,u32)"): k["4"] += v
    elif name == "u64": k["4"] += v - cache_idx - links_idx; k["9"] += cache_idx; k["7"] += links_idx
    elif name == "u32":
        k["1"] += lod.get("u32", 0); k["9b"] += bnd.get("u32", 0) - lod.get("u32", 0); k["9"] += v - bnd.get("u32", 0)
    elif "MappedSymbolLinks" in name or "Links" in name: k["7"] += v
    elif re.search(r"Inference|InferMemo", name): k["10b"] += v
    elif re.search(r"ast\.Flow", name): k["10c"] += v
    elif re.search(r"Diagnostic|checker\.Diag\b", name): k["10d"] += v
    elif re.search(r"Ordered\(checker\.|NodeRef", name): k["9"] += v
    else: k["10g"] += v
tot = sum(k.values()); ts = TS[p]
print(f"| kind | Trig MiB | tsrs shipped | tsrs Go | Trig − Go |\n|---|---:|---:|---:|---:|")
for key in ["1","2","8","3","4","5","6","7","9","9b","10a","10b","10c","10d","10e","10g"]:
    s, g = ts.get(key, (0, 0)); t = k.get(key, 0.0)
    print(f"| {NAMES[key]} | {t:.2f} | {s:.2f} | {g:.2f} | {t-g:+.2f} |")
S = sum(v[0] for v in ts.values()); G = sum(v[1] for v in ts.values())
print(f"| **total** | **{tot:.2f}** | **{S:.2f}** | **{G:.2f}** | **{tot-G:+.2f}** |")
print(f"\n(cache indexes {cache_idx:.2f}, mapped-links index {links_idx:.2f} MiB moved out of the u64 total)")
