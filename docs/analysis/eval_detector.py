import numpy as np, detector_mirror as sp, sys
from synth import render
sp.TRIM=True; sp.WALK=float(sys.argv[1]) if len(sys.argv)>1 else 0.4
conds=[("trees",{}),("sky",{}),("trees",dict(flag=False)),("sky",dict(flag=False)),("trees",dict(stickY=150,stickC=120)),
       ("trees",dict(blur=1.6,noise=4)),("sky",dict(blur=1.6,noise=4)),("trees",dict(wrapped=True)),("sky",dict(wrapped=True))]
print("cond".ljust(40)+"".join(f"{d:>14d}" for d in [50,100,150,200,250]))
for bg,kw in conds:
    line=(bg+" "+str(kw)).ljust(40)
    for yd in [50,100,150,200,250]:
        errs=[]
        for s in range(3):
            Y,C,top,bot,x0=render(yd,seed=s+10*yd+99,bg=bg,**kw)
            q=sp.detect(Y.ravel(),C.ravel(),320,1280,160,384)
            span=2.1336/(yd*0.9144)*13977
            errs.append(None if (q is None or not q['ok']) else -((q['yBot']-q['yTop'])-(bot-top))/span*yd)
        line+="".join("  "+("  --- " if e is None else f"{e:+6.1f}") for e in errs)[-14:].rjust(14) if False else " "+",".join("--" if e is None else f"{e:+.0f}" for e in errs).rjust(13)
    print(line)
