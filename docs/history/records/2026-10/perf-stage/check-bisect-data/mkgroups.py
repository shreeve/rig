import re,os,json,collections,sys
sys.path.insert(0,os.path.dirname(__file__))
from ceil import functions
src="trigsrc/checker"
by=collections.defaultdict(set)
for f in os.listdir(src):
    if f.endswith(".rig"):
        for l in open(os.path.join(src,f)):
            m=re.match(r"\s*(pub )?fun (?:[A-Za-z_0-9]+\.)?([a-z_A-Z0-9]+)",l)
            if m: by[f].add(m.group(2))
store=by["store_generated.rig"]-{"is_nil","len","slice","new"} 
other=set().union(*[v for k,v in by.items() if k!="store_generated.rig"])
store-=other
t=open("pkg0/checker.zig").read()
lines,fns=functions(t)
ins=[n for _,_,n in fns if n in store]
print(len(store),"store names;",len(fns),"fns in checker.zig;",len(ins),"from the store")
json.dump({"checker.zig":sorted(store)},open("cb/g-store.json","w"))
json.dump({"checker.zig":{"not":sorted(store)}},open("cb/g-checker.json","w"))
for g,files in {"binder":["binder.zig"],"ast":["ast.zig","parser.zig","lexer.zig"],"map":["__rig_std_prelude.zig"]}.items():
    json.dump({f:"*" for f in files},open(f"cb/g-{g}.json","w"))
skip={"checker.zig","binder.zig","ast.zig","parser.zig","lexer.zig","__rig_std_prelude.zig","__rig_main.zig"}
json.dump({f:"*" for f in os.listdir("pkg0") if f.endswith(".zig") and f not in skip},open("cb/g-other.json","w"))
