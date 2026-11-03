# lib.py DIR: library (map, hash, vec, string, sort) self cycles of both, classified by the function's own crate, not its generic arguments
import sys,re,collections,os
d=sys.argv[1]
def own(sym):
    s=sym.lstrip('<')
    return re.split(r'[<\s]',s,maxsplit=1)[0]
def cls_tsrs(sym):
    o=own(sym)
    if re.match(r'(hashbrown|indexmap)',o): k='map'
    elif re.match(r'(rustc_hash|foldhash|core::hash)',o): k='hash'
    elif re.match(r'alloc::raw_vec|alloc::vec',o): k='vec grow'
    elif re.match(r'(core::slice::sort|alloc::slice)',o): k='sort'
    elif re.match(r'(memchr|core::str|alloc::str|alloc::string|core::fmt|alloc::fmt|std::)',o): k='string/fmt/io'
    elif re.match(r'(core|alloc)::',o): k='core other'
    elif re.search(r'mi_|mimalloc|memcpy|memmove|memset|malloc|free|bcmp|memcmp',o): k='alloc+memcpy'
    else: return None
    return k
def cls_trig(sym):
    if sym.startswith('rig.ordered') or sym.startswith('rig.unordered'): return 'map'
    if 'hashBytes' in sym or sym.startswith('hash.'): return 'hash'
    if sym.startswith('__rig_std_text.Interner'): return 'interner'
    if re.match(r'rig\.runtime\.(ListOf|reallocSlice|String\.growBy)|rig\.table',sym): return 'vec grow'
    if re.match(r'(__rig_std_sort|rig\.runtime\.(swap|FnRef)|sort\.)',sym): return 'sort (+FnRef thunks)'
    if re.match(r'(mem\.eql|mem\.)',sym): return 'mem.eql etc'
    if re.match(r'(Io\.|fmt\.|rig\.runtime\.String|__rig_std_text|__rig_std_utf)',sym): return 'string/fmt/io'
    if re.match(r'rig\.runtime\.(dropElement|cloneValue)',sym): return 'drop/clone'
    if re.match(r'(rig\.alloc|compiler_rt\.mem|memcpy|memmove|memset)',sym): return 'alloc+memcpy'
    if re.match(r'(rig\.|__rig_std|debug\.|heap\.)',sym): return 'runtime other'
    return None
for v in ('trig','tsrs'):
    c=collections.Counter(); t=0
    for l in open(os.path.join(d,'self.%s.txt'%v)):
        if '[.]' not in l: continue
        n=int(l.split('|')[1]); s=l.split('[.]',1)[1].strip(); t+=n
        k=(cls_trig if v=='trig' else cls_tsrs)(s)
        if k: c[k]+=n
    cyc=int(re.search(r'cycles=(\d+)',open(os.path.join(d,'stat.%s'%v)).read()).group(1))
    sc=lambda n:n/t*cyc/1e6
    tot=sum(x for k,x in c.items() if k!='alloc+memcpy')
    print('%s %s: library less alloc %.1f Mcycles (%.1f%% of %.0f)'%(os.path.basename(d),v,sc(tot),100*sc(tot)/(cyc/1e6),cyc/1e6))
    for k,x in c.most_common(): print('   %7.1f %s'%(sc(x),k))
