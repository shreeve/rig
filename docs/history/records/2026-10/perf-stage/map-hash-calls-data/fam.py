# fam.py DIR: Trig and tsrs self cycles by the same families, scaled to perf stat's user cycles, plus kernel cycles
import sys, re, collections, os
d=sys.argv[1]
AREAS=[('check: relations',r'relat|compare_|assignable|identical|comparable'),
       ('check: instantiate/mappers',r'instantiat|mapper|_map\b|map_type'),
       ('check: inference',r'infer'),
       ('check: unions/intersections',r'union|intersection|reduced|subtype_reduc|remove_.*types'),
       ('check: members/properties',r'member|propert|signatures_of|index_info|resolve_structured|resolve_declared|apparent'),
       ('check: flow/narrowing',r'flow|narrow'),
       ('check: types from nodes',r'type_from|type_of_|declared_type|type_node'),
       ('check: checking/diagnostics',r'^check_|diagnostic|report'),]
def method(sym):
    s=re.sub(r'<[^<>]*>','',sym) if sym.startswith('<') else sym
    s=sym.split('::')[-1] if '::' in sym else sym.split('.')[-1]
    s=re.sub(r'\{closure.*','',s); s=re.sub(r'__func_\d+','',s)
    return s.lower()
def family(sym, trig):
    if trig:
        if sym.startswith('lexer.'): return 'lex'
        if sym.startswith('parser.'): return 'parse'
        if sym.startswith('binder.'): return 'bind'
        if sym.startswith('ast.'): return 'ast (tree access, parents)'
        if sym.startswith('checker.'): mod='check'
        elif re.match(r'(compiler|execute|program|tspath|module|vfs|tsoptions|fileloader|outputpaths|diagnostics|jsnum|core\.)',sym): return 'program, paths, output'
        elif re.match(r'(rig\.alloc|compiler_rt\.mem|_platform_mem|memcpy|memmove|memset)',sym): return 'alloc + memcpy'
        elif re.match(r'(rig\.|__rig_std|hash\.|mem\.|Io\.|debug\.|heap\.|sort\.|fmt\.)',sym): return 'runtime/std (maps, hash, interner)'
        else: return 'other'
    else:
        if 'tsrs_scanner' in sym: return 'lex'
        if 'tsrs_parser' in sym: return 'parse'
        if 'tsrs_binder' in sym: return 'bind'
        if 'tsrs_ast' in sym: return 'ast (tree access, parents)'
        if 'tsrs_checker' in sym: mod='check'
        elif re.search(r'tsrs_(compiler|execute|tspath|module|vfs|tsoptions|outputpaths|diagnostics|jsnum|core|evaluator|sourcemap|printer|scanner)',sym): return 'program, paths, output'
        elif re.search(r'mi_|mimalloc|__mem|memcpy|memmove|memset|_int_malloc|malloc|free',sym): return 'alloc + memcpy'
        elif re.search(r'hashbrown|core::|alloc::|std::|memchr|rayon|crossbeam|__memcmp|bcmp|foldhash|rustc_hash|indexmap',sym): return 'runtime/std (maps, hash, interner)'
        else: return 'other'
    m=method(sym)
    for name,pat in AREAS:
        if re.search(pat,m): return name
    return 'check: other'
def load(v):
    c=collections.Counter(); t=0
    for l in open(os.path.join(d,'self.%s.txt'%v)):
        if '[.]' not in l: continue
        f=l.split('|'); n=int(f[1]); sym=l.split('[.]',1)[1].strip()
        c[family(sym, v=='trig')]+=n; t+=n
    st=open(os.path.join(d,'stat.%s'%v)).read()
    cyc=int(re.search(r'cycles=(\d+)',st).group(1))
    return {k:v_/t*cyc/1e6 for k,v_ in c.items()}, cyc/1e6
tr,tc=load('trig'); ts,sc=load('tsrs')
print("%s: user Mcycles a run, Trig %.1f, tsrs %.1f (gap %.1f, %.1f%% of Trig)"%(os.path.basename(d.rstrip('/')),tc,sc,tc-sc,100*(tc-sc)/tc))
print("| family | Trig | tsrs | gap | gap, % of Trig |")
print("|---|---|---|---|---|")
for k in sorted(set(tr)|set(ts), key=lambda k:-(tr.get(k,0)-ts.get(k,0))):
    a,b=tr.get(k,0),ts.get(k,0)
    print("| %s | %.1f | %.1f | %+.1f | %+.1f%% |"%(k,a,b,a-b,100*(a-b)/tc))
