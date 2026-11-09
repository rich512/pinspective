# Line-by-line mirror of ios/PinSpective/Vision/StickDetector.swift (for testing only).
import math
import numpy as np
def med(a):
    if len(a)==0: return float('nan')
    s=sorted(a); m=len(s)//2
    return s[m] if len(s)%2 else (s[m-1]+s[m])/2
def f32(x): return float(np.float32(x))
TRIM=True  # True = Swift app version; False = original web detector
SGN={}
WALK=0.5
def detect(Y,C,rw,rh,sx,sy,aimSigmaX=40.0):
    M=7
    if not(rw>2*M+6 and rh>24): return None
    N=rw*rh
    Ya=np.asarray(Y,np.float32).reshape(rh,rw); Ca=np.asarray(C,np.float32).reshape(rh,rw)
    R=np.zeros((rh,rw),np.float32)
    best=np.zeros((rh,rw-2*M),np.float32)
    xs=slice(M,rw-M)
    for dd in [2,4,7]:
        for A,sc in [(Ya,1.0),(Ca,0.8)]:
            a=A[:,xs]-A[:,M-dd:rw-M-dd]; b=A[:,xs]-A[:,M+dd:rw-M+dd]
            v=np.where(a*b>0,np.minimum(np.abs(a),np.abs(b))*np.float32(sc),0).astype(np.float32)
            best=np.maximum(best,v)
    R[:,xs]=best
    Rf=R.ravel()
    smp=Rf[0:N:7].tolist()
    nm=med(smp); mad=med([abs(v-nm) for v in smp]) or 1
    tau=nm+3*mad+1
    def kadane(p,t,lo,hi):
        cur=0.;st=lo;bs=0.;ba=0;bb=-1
        for y in range(lo,hi):
            v=p[y]-t
            if cur<=0: cur=v; st=y
            else: cur+=v
            if cur>bs: bs=cur;ba=st;bb=y
        return (ba,bb,bs)
    def colProf(x): return np.maximum(np.maximum(R[:,x-1],R[:,x]),R[:,x+1]).tolist()
    runs=[None]*rw; seed=None
    sigX=max(aimSigmaX,rw*0.1); sigY=max(30.0,rh*0.05)
    for x in range(M+1,rw-M-1):
        k=kadane(colProf(x),tau,0,rh); runs[x]=k
        if k[1]<k[0]: continue
        ln=k[1]-k[0]; a=k[0]
        dy= a-sy if sy<a else (sy-a-0.65*ln if sy-a>0.65*ln else 0)
        wsc=k[2]*math.exp(-0.5*((x-sx)/sigX)**2)*math.exp(-0.5*(dy/sigY)**2)
        if seed is None or wsc>seed[4]: seed=(x,k[0],k[1],k[2],wsc)
    if seed is None: return None
    sdx,sda,sdb,sds,_=seed
    K=max(8,int(round(0.4*(sdb-sda+1))))
    xc,ca,cb=sdx,sda,sdb
    lo4,hi4=max(M+1,sdx-K),min(rw-M-2,sdx+K)
    for x in range(lo4,hi4+1):
        k=runs[x]
        if k is None or not(k[1]>=k[0]) or not(k[2]>=0.15*sds): continue
        if k[1]<sda-3 or k[0]>sdb+3: continue
        sl=sdb-sda
        if k[0]<sda-0.3*sl-3 or k[1]<sdb+0.5*sl: continue
        if k[1]-k[0]>cb-ca: xc,ca,cb=x,k[0],k[1]
    pc=colProf(xc)
    SGN.clear()
    if TRIM:
        q=max(10,(cb-ca)//4); core=med(pc[max(ca,cb-q):cb+1])
    else:
        core=med(pc[ca:cb+1])
    tau2=max(tau,0.3*core)
    a,b=ca,cb
    k=kadane(pc,tau2,max(0,ca-4),min(rh,cb+5))
    if TRIM:
        if k[1]>=k[0] and (k[1]-k[0])>0.6*(cb-ca): a,b=k[0],k[1]
        # walk up from the base while a 5-row median stays above half the stick strength
        # signed thin-line profile at the stick column (max over xc-1..xc+1 of centre minus sides)
        def sprof(sgn):
            out=[]
            for yy in range(rh):
                o=yy*rw; m=-1e9
                for x in (xc-1,xc,xc+1):
                    v=sgn*(Ya.ravel()[o+x]-(Ya.ravel()[o+x-2]+Ya.ravel()[o+x+2])/2)
                    if v>m: m=v
                out.append(m)
            return out
        q4=max(10,(b-a)//4)
        sp_=sprof(1.0); seg=sp_[max(a,b-q4):b+1]; sgn=1.0 if med(seg)>=0 else -1.0
        if sgn<0: sp_=[-v for v in sp_]
        cs=med(sp_[max(a,b-q4):b+1])
        SGN['sp']=sp_; SGN['thr']=WALK*cs if cs>3 else None
        if cs>3:
            thr=WALK*cs; y=b-4
            while y-1>=a and med(sp_[max(0,y-5):y+4])>=thr: y-=1
            if b-y>=6: a=max(a,y)
    elif k[1]>=k[0] and (k[1]-k[0])>0.6*(cb-ca): a,b=k[0],k[1]
    Yf=Ya.ravel(); Cf=Ca.ravel()
    def E(y):
        m=0.;o=y*rw;x0=max(4,xc-3);x1=min(rw-5,xc+3)
        for x in range(x0,x1+1):
            l=(Yf[o+x-1]+Yf[o+x-2]+Yf[o+x-3])/3; r=(Yf[o+x+1]+Yf[o+x+2]+Yf[o+x+3])/3
            lc=(Cf[o+x-1]+Cf[o+x-2]+Cf[o+x-3])/3; rc=(Cf[o+x+1]+Cf[o+x+2]+Cf[o+x+3])/3
            v=max(abs(l-r),0.8*abs(lc-rc)); m=max(m,v)
        return m
    es=[]
    if TRIM:
        def Eat(y,xm):
            m=0.;o=y*rw
            for x in range(xm-3,xm+4):
                l=(Yf[o+x-1]+Yf[o+x-2]+Yf[o+x-3])/3; r=(Yf[o+x+1]+Yf[o+x+2]+Yf[o+x+3])/3
                lc=(Cf[o+x-1]+Cf[o+x-2]+Cf[o+x-3])/3; rc=(Cf[o+x+1]+Cf[o+x+2]+Cf[o+x+3])/3
                m=max(m,abs(l-r),0.8*abs(lc-rc))
            return m
        for i in range(400):
            y=(i*37)%rh; x=13+((i*101)%max(1,rw-26)); es.append(Eat(y,x))
    else:
      for i in range(400):
        y=(i*37)%rh; x=10+((i*101)%max(1,rw-20)); o=y*rw+x
        es.append(abs((Yf[o-1]+Yf[o-2]+Yf[o-3])/3-(Yf[o+1]+Yf[o+2]+Yf[o+3])/3))
    em=med(es); emad=med([abs(v-em) for v in es]) or 1; tauE=em+4*emad+3
    top=a;usedE=False;gap=0;hits=0
    lim=max(0,int(math.floor(a-0.45*(b-a+1))))
    y=a-1
    while y>=lim:
        byR=(SGN['sp'][y]>=SGN['thr']) if (TRIM and SGN.get('thr')) else pc[y]>tau2
        byE=(not byR) and E(y)>tauE
        if byR or byE:
            top=y;gap=0;hits+=1
            if byE: usedE=True
        else:
            gap+=1
            if gap>2: break
        y-=1
    if TRIM and top<a and usedE:
        # Cloth check: one edge at a fixed column with consistent polarity, and a flag-sized extension.
        n=a-top; okc=False
        if 0.06*(b-a)<=n<=0.3*(b-a):
            best=0
            for col in range(max(4,xc-3),min(rw-5,xc+3)+1):
                for A in (Yf,Cf):
                    pos=neg=0
                    for yy in range(top,a):
                        o=yy*rw+col
                        v=(A[o-1]+A[o-2]+A[o-3])/3-(A[o+1]+A[o+2]+A[o+3])/3
                        if v>tauE: pos+=1
                        elif v<-tauE: neg+=1
                    best=max(best,pos,neg)
            okc= best>=0.85*n
        if not okc: top=a; usedE=False
    blobTop=None
    if TRIM and top==a and a>8:
        def bandv(A,y,c0,c1): return sum(A[y*rw+x] for x in range(c0,c1+1))/(c1-c0+1)
        ref=[(bandv(Yf,y,xc-1,xc+1),bandv(Cf,y,xc-1,xc+1)) for y in range(a-6,a-1)]
        rY=med([v[0] for v in ref]); rC=med([v[1] for v in ref]); tol=12
        def like(y,c0,c1): return abs(bandv(Yf,y,c0,c1)-rY)<tol and abs(bandv(Cf,y,c0,c1)-rC)<tol
        lim2=max(0,int(a-0.3*(b-a))); y=a-1; bt=a; miss=0
        wl,wr=max(0,xc-3),min(rw-1,xc+3)
        while y>=lim2:
            if like(y,xc-1,xc+1) and like(y,wl,wl+1) and like(y,wr-1,wr): bt=y; miss=0
            else:
                miss+=1
                if miss>1: break
            y-=1
        n=a-bt
        if y>=lim2-1 and 0.06*(b-a)<=n<=0.3*(b-a) and bt>=5:
            diff=sum(1 for yy in range(bt-4,bt) if not like(yy,xc-1,xc+1))
            if diff>=3: blobTop=bt
    if blobTop is not None:
        top=blobTop; usedE=True
    if sdx!=xc and sda<top and sdb>=top-3 and sdb<=a+0.35*(b-a) and (top-sda)<0.45*(b-a): top=sda
    cl=lambda v: 0 if not math.isfinite(v) else max(-0.5,min(0.5,v))
    L=(core+nm)/2; yTop=float(top); yBot=float(b+1)
    if blobTop is not None:
        bvY=lambda y: sum(Yf[y*rw+x] for x in range(xc-1,xc+2))/3
        v0,v1=bvY(blobTop),bvY(blobTop-1); mid=(rY+v1)/2
        yTop=blobTop+0.5-cl((v0-mid)/(v0-v1)) if abs(v0-v1)>1e-3 else float(blobTop)
    elif top==a and a>0 and pc[a]>pc[a-1]: yTop=a+0.5-cl((pc[a]-L)/(pc[a]-pc[a-1]))
    elif top!=a and top>0:
        ev=[E(yy) for yy in range(top,a)]; eL=(med(ev)+em)/2; yy=top
        while yy<a-1 and E(yy)<eL: yy+=1
        e0,e1=E(yy),E(yy-1)
        yTop=yy+0.5-cl((e0-eL)/(e0-e1)) if e0>e1 else float(yy)
    if b<rh-1 and pc[b]>pc[b+1]: yBot=b+0.5+cl((pc[b]-L)/(pc[b]-pc[b+1]))
    contrast=core/tau
    return dict(x=xc+0.5,yTop=yTop,yBot=yBot,contrast=contrast,flag=usedE,ok=(yBot-yTop>=6 and contrast>=1.2))
