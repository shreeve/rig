import sys
for fn in sys.argv[1:]:
    ev={}; starts=[]; ends=[]; spawns=[]
    for l in open(fn):
        f=l.split(); k=f[1]; t=int(f[-1]); name=f[2] if len(f)>3 else ''
        ev.setdefault((k,name),t)
        if k=='start': starts.append(t)
        if k=='end' and 'dom' not in name: ends.append(t)
        if k=='spawn': spawns.append(t)
    D='bundled:///libs/lib.dom.d.ts'
    g=lambda k,n='': ev.get((k,n))
    lastgot=max(t for (k,n),t in ev.items() if k=='got')
    print(f"{fn.split('/')[-1]:18} closure {g('closure')/1000:.2f} spawns {spawns[0]/1000:.2f}-{spawns[-1]/1000:.2f} | dom spawn->start {(g('start',D)-g('spawn',D))/1000:.2f} parse {(g('end',D)-g('start',D))/1000:.2f} | others done {max(ends)/1000:.2f} | walk {g('walk')/1000:.2f} waits dom {g('wait',D)/1000:.2f}->{g('got',D)/1000:.2f} ({(g('got',D)-g('wait',D))/1000:.2f}) | libs taken {lastgot/1000:.2f} walk-done {g('walk-done')/1000:.2f} ({(g('walk-done')-lastgot)/1000:.2f} own files) | bind {(g('bind-done')-g('bind'))/1000:.2f} | checkers {(g('checkers-done')-g('checkers'))/1000:.2f} | end {g('checkers-done')/1000:.2f}")
