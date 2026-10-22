import re, sys
# Renumber SPEC sections >= 3 down by one. mode 'spec' for SPEC.md itself; 'other' for links into SPEC.md from other files.
def dec(n): n=int(n); return str(n-1) if n>=3 else str(n)
def fix_spec(s):
    s = re.sub(r'^## (\d+)\. ', lambda m: f'## {dec(m.group(1))}. ', s, flags=re.M)
    s = re.sub(r'^(\d+)\. \[(.*?)\]\(#(\d+)-', lambda m: f'{dec(m.group(1))}. [{m.group(2)}](#{dec(m.group(3))}-', s, flags=re.M)
    # [§N](#N-slug) or [§N](#anchor) -- only SPEC-internal links (no file part), not "SYNTAX §N"
    s = re.sub(r'(?<!SYNTAX )\[§(\d+)\]\(#', lambda m: f'[§{dec(m.group(1))}](#', s)
    s = re.sub(r'\]\(#(\d+)-', lambda m: f'](#{dec(m.group(1))}-', s)
    return s
def fix_other(s):
    # [SPEC §N](SPEC.md#N-...) and [..](SPEC.md#N-...)
    s = re.sub(r'SPEC §(\d+)', lambda m: f'SPEC §{dec(m.group(1))}', s)
    s = re.sub(r'SPEC\.md#(\d+)-', lambda m: f'SPEC.md#{dec(m.group(1))}-', s)
    return s
for f in sys.argv[2:]:
    t = open(f).read()
    t = fix_spec(t) if sys.argv[1]=='spec' else fix_other(t)
    open(f,'w').write(t)
