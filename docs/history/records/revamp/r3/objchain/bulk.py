import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("mig", "tools/migrate-0.3.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
files = subprocess.check_output(["git","ls-files","*.rig","*.rig.tmpl"], text=True).split()
n=0
for f in files:
    src = open(f).read()
    edits = m.obj_edits(src, f, [])
    if edits:
        open(f,"w").write(m.rewrite_with(src, edits)); n+=1
print(n, "files")
