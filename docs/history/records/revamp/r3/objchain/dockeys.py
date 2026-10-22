import re,sys,subprocess,tempfile,os,glob
def keys(root):
    out={}
    files=sorted(glob.glob(root+'/*.md')+glob.glob(root+'/docs/*.md')+glob.glob(root+'/examples/*.md')+glob.glob(root+'/test/*.md'))
    for md in files:
        doc=os.path.basename(md)[:-3]
        lines=open(md).read().split("\n")
        if lines and lines[-1]=="": lines.pop()
        i=0; n=len(lines); seen={}
        pending={}
        while i<n:
            if not re.match(r"^```rig([ \t]|$)",lines[i]): i+=1; continue
            start=i+1; mode="check"; fname=""; pend=False
            for w in re.split(r"[ \t]+",lines[i][6:]):
                if w=="": continue
                if w in("reject","fragment","facts"): mode=w
                elif w=="pending": pend=True
                elif w.startswith("file="): fname=w[5:]
            body=""
            i+=1
            while i<n and lines[i]!="```": body+=lines[i]+"\n"; i+=1
            i+=1
            j=i
            while j<n and re.match(r"^[ \t]*$",lines[j]): j+=1
            kind="";extra=[]
            if j<n and lines[j] in("```output","```error","```facts"):
                kind=lines[j][3:]; j+=1
                while j<n and lines[j]!="```": extra.append(lines[j]); j+=1
                i=j+1
            if pend and mode=="check" and kind=="error": mode="reject"
            if fname: continue
            if kind=="output" and mode=="check": mode="run"
            text=body
            if mode in("run","reject"):
                text+="\n"+("# expect:" if mode=="run" else "")+"\n"
                for l in extra:
                    text+=("#" if l=="" else "# "+l)+"\n" if mode=="run" else "# error: "+l+"\n"
            if mode=="fragment" or mode.startswith("doc convention"): continue
            with tempfile.NamedTemporaryFile(delete=False) as t: t.write(text.encode())
            c=subprocess.check_output(["cksum",t.name],text=True).split()[0]; os.unlink(t.name)
            key=f"doc/{doc}/{c}"
            seen[key]=seen.get(key,0)+1
            if seen[key]>1: key+=f"-{seen[key]}"
            out[key]=(md,start)
    return out
