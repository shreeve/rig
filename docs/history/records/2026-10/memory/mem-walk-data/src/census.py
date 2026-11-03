# census.py DIR STAGE: Trig's memory at STAGE by kind: Tables (DIR/STAGE.tables, mincore
# resident, from the plain build) and heap owners (DIR/STAGE.owners, live bytes by the
# type allocated, from the heap-profile build). Prints kind totals and the largest rows.
import sys, re, collections
M = 1 << 20
tdir, odir, stage = sys.argv[1], sys.argv[2], sys.argv[3]
TYPES = set("""Type StructuredType StructuredExtra TypeParameter ConditionalType TypeReference UnionOrIntersectionType
UnionOrIntersectionExtra MappedType LiteralType IndexedAccessType InterfaceType SubstitutionType TupleType IndexType
EvolvingArrayType InstantiationExpressionType StringMappingType UniqueESSymbolType IntrinsicType TemplateLiteralType
ReverseMappedType IndexInfo TypeAlias TypePredicate ConditionalRoot""".split())
LISTS_ORDER = ["type_lists", "sym_lists", "sig_lists", "info_lists"]
def table_kind(name):
    n = name.split(".")[-1]
    if n in TYPES: return "5 types"
    if n in ("Signature", "SignatureExtra", "CompositeSignature"): return "6 signatures"
    if n in ("CheckerSymbol", "SymbolData"): return "3 symbols"
    if n.endswith("Links") or n == "ValueSymbolExtra": return "7 links and side tables"
    if n == "TypeMapper": return "10a mappers"
    if n in ("u32", "NodeRef", "ElementInfo"): return "9 lists and maps"
    return "10 other"
def owner_kind(name):
    n = name
    if re.search(r"ast\.(NodeRec|ListRec|Node\b|File\b|NodeList|ModifierList|PragmaArgument|JSDoc)|parser\.", n): return "1 AST nodes"
    if re.search(r"ast\.TextRec|^u8$", n): return "2 identifiers and text"
    if re.search(r"ast\.SymbolRec", n): return "3 symbols"
    if re.search(r"ast\.FlowRec|ast\.FlowListRec", n): return "10c flow nodes"
    if re.search(r"Inference", n): return "10b inference"
    if re.search(r"Diagnostic|checker\.Diag\b", n): return "10d diagnostics"
    if re.search(r"Map\(|Ordered\(|Set\(|hash\.|Unordered\(", n): return "9 lists and maps"
    if n in ("u32", "u64", "i64", "usize"): return "9 lists and maps"
    if re.search(r"compiler\.|module\.|tsoptions\.|tspath\.|vfs\.|rig\.runtime\.String", n): return "10g program, config, module resolution, other"
    return "10 other"
kinds = collections.defaultdict(float); rows = []
try:
    for l in open(f"{tdir}/{stage}.tables"):
        res, size, n, p, nbytes, name = l.split(None, 5); name = name.strip()
        if int(res) == 0: continue
        k = table_kind(name); kinds[k] += int(res) / M
        rows.append((int(res) / M, k, f"Table {name} ({size} B)", int(res) // int(size)))
except FileNotFoundError: pass
try:
    for l in open(f"{odir}/{stage}.owners"):
        live, blocks, made, name = l.split(None, 3); name = name.strip()
        k = owner_kind(name); kinds[k] += int(live) / M
        rows.append((int(live) / M, k, f"heap {name}", int(blocks)))
except FileNotFoundError: pass
print(f"## {stage}: total {sum(kinds.values()):.1f} MiB")
for k in sorted(kinds): print(f"| {k} | {kinds[k]:.2f} |")
print()
for mib, k, what, c in sorted(rows, reverse=True)[:int(sys.argv[4]) if len(sys.argv) > 4 else 40]:
    print(f"| {k} | {what} | {c:,} | {mib:.2f} |")
