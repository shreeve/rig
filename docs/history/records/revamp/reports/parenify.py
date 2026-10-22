import re, sys

KEYWORDS = set('''and as async await break catch const continue defer drop else enum errdefer error extern false for fun if impl in match new not or pub raw return struct sub test trait true try type use when where while yield zig of'''.split())
INFIX = ['==','!=','<=','>=','+=','-=','*=','/=','%=','&=','|=','^=','<<=','>>=','+%=','-%=','*%=','=!','=>','->','??','..','<<','>>','+%','-%','*%','=','<','>','+','-','*','/','%','&','|','^',':',',',')',']']
WORD_INFIX = {'and','or','as','catch','if','else','in','of'}

def split_comment(line):
    # find '#' outside strings
    q=None; i=0
    while i < len(line):
        c=line[i]
        if q:
            if c=='\\' and q=='"': i+=2; continue
            if c==q: q=None
        else:
            if c in '"\'': q=c
            elif c=='#': return line[:i], line[i:]
        i+=1
    return line, ''

def match_callee(s):
    # optional receiver sigil, name chain with optional [..] ct args
    m = re.match(r'([!?<]?)([A-Za-z_]\w*)((?:\.[A-Za-z_]\w*)*)', s)
    if not m: return None
    name = m.group(2)
    if name in KEYWORDS: return None
    end = m.end()
    # bracket list after name?
    if end < len(s) and s[end] == '[':
        d=0; j=end
        while j < len(s):
            if s[j]=='[': d+=1
            elif s[j]==']':
                d-=1
                if d==0: break
            j+=1
        if j >= len(s): return None
        end = j+1
        m2 = re.match(r'((?:\.[A-Za-z_]\w*)*)', s[end:])
        end += m2.end()
    return end

def top_split(s):
    parts=[]; d=0; q=None; cur=0; i=0
    while i < len(s):
        c=s[i]
        if q:
            if c=='\\' and q=='"': i+=2; continue
            if c==q: q=None
        elif c in '"\'': q=c
        elif c in '([': d+=1
        elif c in ')]': d-=1
        elif c==',' and d==0:
            parts.append(s[cur:i]); cur=i+1
        i+=1
    parts.append(s[cur:])
    return parts

def find_guard(s):
    # position of a top-level ' if ' that is a postfix guard (no 'else' after at depth 0)
    d=0; q=None; i=0
    while i < len(s):
        c=s[i]
        if q:
            if c=='\\' and q=='"': i+=2; continue
            if c==q: q=None
        elif c in '"\'': q=c
        elif c in '([': d+=1
        elif c in ')]': d-=1
        elif d==0 and s.startswith(' if ', i):
            rest = s[i+4:]
            if not re.search(r'\belse\b', rest):
                return i
        i+=1
    return -1

def is_arg_start(rest):
    if not rest: return False
    for op in INFIX:
        if rest.startswith(op):
            # sigils that are prefixes when followed by operand
            if op in ('<','+','-','*') and len(rest)>1 and (rest[1].isalnum() or rest[1] in '_([."\'<?!+*~-'):
                return True
            if op == '|' and len(rest) > 1 and rest[1] not in ' |=':
                return True  # closure bar
            return False
    w = re.match(r'[A-Za-z_]\w*', rest)
    if w and w.group(0) in WORD_INFIX: return False
    return rest[0].isalnum() or rest[0] in '_"\'[(.!?~@|'

MANUAL = []

def cut_rest(rest):
    """Split rest at the first unmatched closer; return (inside, after, balanced)."""
    d=0; q=None; i=0
    while i < len(rest):
        c=rest[i]
        if q:
            if c=='\\' and q=='"': i+=2; continue
            if c==q: q=None
        elif c in '"\'': q=c
        elif c in '([': d+=1
        elif c in ')]':
            if d==0: return rest[:i], rest[i:], True
            d-=1
        i+=1
    return rest, '', d==0

def convert_cmd(s):
    """s starts at a command position; return converted string or None."""
    end = match_callee(s)
    if end is None: return None
    if end >= len(s) or s[end] != ' ': return None
    rest = s[end+1:]
    if not is_arg_start(rest): return None
    rest, after, balanced = cut_rest(rest)
    if not balanced or rest.rstrip().endswith('|'):
        MANUAL.append(s)
        return None
    # `x (y)` where rest is fully parenthesized: fine either way; convert anyway
    g = find_guard(rest)
    tail = ''
    if g >= 0:
        tail = rest[g:]
        rest = rest[:g]
    rest_stripped = rest.rstrip()
    trailing = rest[len(rest_stripped):]
    parts = top_split(rest_stripped)
    for i, part in enumerate(parts):
        lead = len(part) - len(part.lstrip())
        joined = ','.join(parts[i:])
        inner = convert_cmd(joined.lstrip())
        if inner is not None:
            parts = parts[:i] + [part[:lead] + inner]
            break
    return s[:end] + '(' + ','.join(parts) + ')' + trailing + tail + after

def convert_line(line):
    code, comment = split_comment(line)
    if not code.strip(): return line
    ind = len(code) - len(code.lstrip(' '))
    body = code[ind:]
    # statement-level command
    for prefix_re in [r'', r'(defer |errdefer )', ]:
        pass
    m = re.match(r'(defer |errdefer )?', body)
    pre = m.group(0)
    new = convert_cmd(body[len(pre):])
    if new is not None:
        return code[:ind] + pre + new + comment
    # after `=> `
    k = body.find(' => ')
    if k >= 0:
        new = convert_cmd(body[k+4:])
        if new is not None:
            return code[:ind] + body[:k+4] + new + comment
    # closure body after `| ` at end of bar list: `|...| cmd` (outside parens only, simple)
    for mm in re.finditer(r'\|\| |[|][^|]*[^ |]\| ', body):
        j = mm.end()
        seg = body[j:]
        new = convert_cmd(seg)
        if new is not None:
            return code[:ind] + body[:j] + new + comment
    return line

def convert_text(text):
    return '\n'.join(convert_line(l) for l in text.split('\n'))

if __name__ == '__main__':
    for path in sys.argv[1:]:
        src = open(path).read()
        if path.endswith('.md'):
            out=[]; inrig=False
            for l in src.split('\n'):
                if l.startswith('```rig'):
                    inrig=True; out.append(l); continue
                if inrig and l.startswith('```'):
                    inrig=False; out.append(l); continue
                out.append(convert_line(l) if inrig else l)
            new='\n'.join(out)
        else:
            new = convert_text(src)
        if new != src:
            open(path,'w').write(new)
            print('changed', path)
        for m in MANUAL:
            print('MANUAL', path, m)
        MANUAL.clear()
