import math
YD=0.9144
# iPhone 16 Pro Max 5x: 120 mm-equivalent, 12 MP (4032x3024), f/2.8, ~1.12 um pixels (nominal, to be replaced by calibration)
W=4032; diag35=43.27; w35=diag35*0.8
fpx=W*120/w35
print(f"nominal fx = {fpx:.0f} px  IFOV = {1e6/fpx:.1f} urad/px  HFOV(long side) = {2*math.degrees(math.atan(W/2/fpx)):.2f} deg")
f_mm=fpx*1.12e-3; D_ap=f_mm/2.8
airy=1.22*0.55e-6/(D_ap*1e-3)
print(f"focal ~{f_mm:.1f} mm, aperture ~{D_ap:.1f} mm, Airy radius {airy*1e6:.0f} urad = {airy*fpx:.1f} px")
H=84*0.0254
print("\nMethod A (7 ft visible stick):")
print(" yd   span_px  mm/px   need_span_px(1sig=2yd)  need_H_in(1sig=2yd)  1px span err->yd")
for yd in [50,100,150,200,250]:
    D=yd*YD; span=H/D*fpx
    rel=2/yd
    print(f"{yd:4d} {span:8.0f} {D/fpx*1000:6.1f} {rel*span:14.2f} {rel*84:20.2f} {yd/span:16.2f}")
# error budget at 200 yd, good case
print("\nError budget at 200 yd (1 sigma, relative):")
span=H/(200*YD)*fpx
cases={
 "pixel noise after 30-frame average (~1 px total on span)":1.0/span,
 "flag height measured with tape (+-0.5 in)":0.5/84,
 "flag height assumed 7 ft, unknown course (+-6 in)":6/84,
 "base partly hidden by grass/lip (+-1 in)":1.0/84,
 "focal length field-calibrated (+-0.5%)":0.005,
 "focal length from Apple intrinsics only (+-2%, unverified)":0.02,
}
for k,v in cases.items(): print(f"  {k:62s} {v*100:5.2f}%  = {v*200:5.1f} yd")
best=math.sqrt((1/span)**2+(0.5/84)**2+(1/84)**2+0.005**2)
print(f"  BEST realistic total: {best*100:.2f}% -> 1sig {best*200:.1f} yd, 95% +-{1.96*best*200:.1f} yd")
unk=math.sqrt((1/span)**2+(6/84)**2+(1/84)**2+0.02**2)
print(f"  Unknown flag height + uncalibrated: {unk*100:.1f}% -> 95% +-{1.96*unk*200:.0f} yd")
# shimmer: angle-of-arrival sigma^2 = 2.91 Cn2 L D^-1/3
print("\nHeat shimmer (angle-of-arrival jitter, 200 yd path):")
for name,cn2 in [("cool/overcast",1e-14),("moderate",1e-13),("sunny afternoon",1e-12),("hot, low over grass",1e-11)]:
    s=math.sqrt(2.91*cn2*200*YD*(D_ap*1e-3)**(-1/3))
    print(f"  {name:22s} Cn2={cn2:.0e}  sigma={s*1e6:6.0f} urad = {s*fpx:4.2f} px per edge per frame")
print("\nMethod B (sideways baseline b, target 200 yd, need 1sig 2 yd = 1.09%):")
D=200*YD
for b in [0.5,1,2,5,10,30]:
    th=b/D; need=th*2/200
    print(f"  b={b:5.1f} m  parallax={th*1e3:6.2f} mrad ({th*fpx:6.0f} px)  need angle 1sig={need*1e6:6.1f} urad ({math.degrees(need):.4f} deg)  need baseline 1sig={b*0.0109*100:5.1f} cm")
for rot_deg in [0.05,0.1,0.3]:
    r=math.radians(rot_deg); bmin=r*D/0.0109
    print(f"  if relative rotation known to {rot_deg} deg -> baseline needed >= {bmin:5.1f} m ({bmin/YD:.0f} yd)")
for Db_ratio in [1.2,1.5,2,4]:
    # background used as rotation reference at Db = ratio*D: estimated D' = 1/(1/D - 1/Db) 
    Dp=1/(1/D-1/(Db_ratio*D))
    print(f"  background reference at {Db_ratio}x pin distance -> reads {Dp/YD:6.0f} yd instead of 200")
