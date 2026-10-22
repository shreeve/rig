import re, subprocess
files = subprocess.check_output("git ls-files '*.md' '*.sh' '*.py' test/run test/oracle/differences test/oracle/rejections", shell=True, text=True).split()
skip = {"test/cli/migrate_tool.sh", "tools/migrate-0.3.py"}
pat = re.compile(r"(?<![A-Za-z0-9_.@`])struct(?= [A-Z][A-Za-z0-9_]*)")
for f in files:
    if f in skip: continue
    s = open(f).read()
    t = pat.sub("obj", s)
    if t != s:
        open(f, "w").write(t); print(f, len(pat.findall(s)))
