# Independent check of FrameGeometry conventions (mirrors the Swift code line by line).
import numpy as np, math
fx=fy=14000.; cx,cy=2016.,1512.
def rot(axis, a):
    axis=np.array(axis,float); axis/=np.linalg.norm(axis); K=np.array([[0,-axis[2],axis[1]],[axis[2],0,-axis[0]],[-axis[1],axis[0],0]])
    return np.eye(3)+math.sin(a)*K+(1-math.cos(a))*K@K
# world: E,N,U. Device columns expressed in world for upright portrait facing north:
Rdw0=np.column_stack([[1,0,0],[0,0,1],[0,-1,0]])  # dev x=E, dev y=U, dev z=S (screen faces user)
def swift_geo(g):
    gx,gy,gz=g/np.linalg.norm(g); ip=math.hypot(gx,gy); return dict(up=(gy/ip,gx/ip), g=(gx,gy,gz))
def bufpt_to_roi(geo,origin,anchor,p):
    upX,upY=geo['up']; right=(-upY,upX); down=(-upX,-upY)
    dx,dy=p[0]-origin[0],p[1]-origin[1]
    return (anchor[0]+dx*right[0]+dy*right[1], anchor[1]+dx*down[0]+dy*down[1])
def elev(geo,p,k=1):
    gx,gy,gz=geo['g']; rx=(p[0]-cx)/(k*fx); ry=(p[1]-cy)/(k*fy); n=math.sqrt(rx*rx+ry*ry+1)
    return math.asin((rx*gy+ry*gx+gz)/n)
worst=0
for pitch in [-4,0,3,8]:
  for roll in [-10,-3,0,5,12]:
    for yaw in [0,0.3]:
      # rotate device: pitch about device x (tilts camera up), roll about device z (optical axis)
      Rdw=Rdw0@rot([1,0,0],math.radians(pitch))@rot([0,0,1],math.radians(roll))
      Rdw=rot([0,0,1],math.radians(yaw))@Rdw
      g_dev=Rdw.T@np.array([0,0,-1.])
      cam_in_dev=np.column_stack([[0,-1,0],[-1,0,0],[0,0,-1]])  # cam x,y,z in device coords
      Rcw=Rdw@cam_in_dev
      C=np.array([0,0,1.5])
      for Xtrue,base_z in [(45.72,0.0),(182.88,-2.0),(228.6,3.0)]:
        H=2.1336
        # put the pin roughly along the camera axis
        fwd=Rcw[:,2]; dirh=np.array([fwd[0],fwd[1],0]); dirh/=np.linalg.norm(dirh)
        side=np.cross([0,0,1],dirh)
        B=C*0+np.array([0,0,0.])+dirh*Xtrue+side*1.0; B[2]=base_z; T=B+np.array([0,0,H])
        def proj(P):
            q=Rcw.T@(P-C); return (fx*q[0]/q[2]+cx, fy*q[1]/q[2]+cy)
        pt,pb=proj(T),proj(B)
        geo=swift_geo(g_dev)
        anchor=(160,384); origin=pt
        ut,vt=bufpt_to_roi(geo,origin,anchor,pt); ub,vb=bufpt_to_roi(geo,origin,anchor,pb)
        X=H/(math.tan(elev(geo,pt))-math.tan(elev(geo,pb)))
        err=abs(X-Xtrue)/Xtrue; worst=max(worst,err)
        assert vb>vt, ("base not below top",pitch,roll)
        assert abs(ub-ut)<0.06*(vb-vt), ("stick not vertical in ROI",pitch,roll,ub-ut,vb-vt)
print(f"all orientations OK; worst relative distance error from geometry = {worst:.2e}")
# also: Swift pitch/roll helpers
Rdw=Rdw0@rot([1,0,0],math.radians(5)); g=Rdw.T@np.array([0,0,-1.])
print("pitch +5 deg ->", round(math.degrees(math.asin(g[2])),3), " roll ->", round(math.degrees(math.atan2(g[0],-g[1])),3))
