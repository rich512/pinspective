import numpy as np, math
from scipy.ndimage import gaussian_filter, zoom
YD=0.9144; FX=13977.0
def render(yd, rw=320, rh=1280, seed=0, blur=0.85, noise=2.0, bg="trees", flag=True, wrapped=False, stickY=225, stickC=40, shimmer=0.0):
    """Gravity-aligned ROI: aim point at (rw/2, 0.3*rh) near the stick top. Returns Y,C,true top,true base."""
    rng=np.random.default_rng(seed)
    S=4  # supersample
    D=yd*YD; mpp=D/FX
    H=2.1336; span=H/mpp
    W,Hh=rw*S,rh*S
    yy,xx=np.mgrid[0:Hh,0:W]/S
    # background
    if bg=="trees":
        base=gaussian_filter(rng.normal(0,1,(rh,rw)),3); base=60+25*base/base.std()
        Yb=np.kron(base,np.ones((S,S))); Cb=np.full_like(Yb,70.)
    else:
        Yb=np.full((Hh,W),200.)+np.kron(gaussian_filter(rng.normal(0,1,(rh,rw)),6)*3,np.ones((S,S))); Cb=np.full_like(Yb,30.)
    top=0.3*rh-0.15*span+rng.uniform(-3,3); bot=top+span
    x0=rw/2+rng.uniform(-6,6)
    green=yy>=bot+0.0
    Y=Yb.copy(); C=Cb.copy()
    Y[green]=95; C[green]=75
    wpx=0.0127/mpp
    st=(np.abs(xx-x0)<wpx/2)&(yy>=top)&(yy<bot)
    Y[st]=stickY; C[st]=stickC
    if wrapped:
        fw,fh=0.20/mpp,0.45/mpp
        fl=(np.abs(xx-x0)<fw/2)&(yy>=top)&(yy<top+fh)
        Y[fl]=190; C[fl]=160
    elif flag:
        fw,fh=0.508/mpp,0.356/mpp
        fl=(xx>=x0)&(xx<x0+fw)&(yy>=top)&(yy<top+fh)
        Y[fl]=190; C[fl]=160
    Y=Y.reshape(rh,S,rw,S).mean(axis=(1,3)); C=C.reshape(rh,S,rw,S).mean(axis=(1,3))
    Y=gaussian_filter(Y,blur)+rng.normal(0,noise,Y.shape); C=gaussian_filter(C,blur)+rng.normal(0,noise,C.shape)
    return np.clip(Y,0,255).astype(np.float32), np.clip(C,0,255).astype(np.float32), top, bot, x0
