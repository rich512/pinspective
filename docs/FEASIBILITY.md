# PinSpective: can an iPhone 16 Pro Max camera measure flagstick distance?

Status: **unvalidated**. Everything below is physics, arithmetic and synthetic-image tests. No
real-world measurement has been made yet. The numbers that matter will come from the field test
in `ios/README.md`.

## 1. The camera

Nominal values for the 5× telephoto (120 mm-equivalent, 12 MP, f/2.8). The app reads the real
focal length from the camera's intrinsic matrix every frame, and a field calibration corrects it.

| Quantity | Value |
|---|---|
| Focal length in pixels (4032 px long side) | ≈ 13,980 px |
| Angle per pixel | ≈ 71.5 µrad (0.0041°) |
| Field of view, long side | ≈ 16.4° |
| Diffraction (Airy radius, 550 nm) | ≈ 120 µrad ≈ 1.7 px |

The optics blur a point over about 2 px, so a 1-px-wide flagstick shows up as a faint 2–3 px line.
That is enough to locate an edge to a fraction of a pixel (with good contrast), but not enough to
see fine detail.

## 2. Method A: known flagstick height

Distance = visible stick height ÷ angular height. The app uses the exact form
`X = H / (tan e_top − tan e_base)`, with the elevation angles of the top and base rays taken from
the camera intrinsics and Core Motion gravity. That handles pitch and roll exactly; a simulation
over pitch −4…+8° and roll −10…+12° recovers distance to 0.02%.

Size of a 7 ft (84 in) visible stick in the image, and the precision each input needs for
**1σ = 2 yd** (so the 95% range is about ±4 yd):

| Distance | Stick height in image | mm per pixel | Span precision needed | Flag height precision needed | Distance error per 1 px of span error |
|---|---|---|---|---|---|
| 50 yd | 652 px | 3.3 | ±26 px | ±3.4 in | 0.08 yd |
| 100 yd | 326 px | 6.5 | ±6.5 px | ±1.7 in | 0.31 yd |
| 150 yd | 217 px | 9.8 | ±2.9 px | ±1.1 in | 0.69 yd |
| 200 yd | 163 px | 13.1 | ±1.6 px | ±0.8 in | 1.23 yd |
| 250 yd | 130 px | 16.4 | ±1.0 px | ±0.7 in | 1.92 yd |

**Error budget at 200 yd (1σ):**

| Source | Relative | Yards |
|---|---|---|
| Pixel noise after a 30-frame average (≈1 px on the span) | 0.61% | 1.2 |
| Flag height measured with a tape (±0.5 in) | 0.60% | 1.2 |
| Flag height **assumed** 7 ft on an unknown course (±6 in) | 7.1% | 14.3 |
| Base partly hidden by grass or the cup lip (±1 in, a guess to be tested) | 1.2% | 2.4 |
| Focal length field-calibrated (±0.5%) | 0.5% | 1.0 |
| Focal length from Apple's intrinsics only (±2%, unverified) | 2.0% | 4.0 |
| **Best realistic total** (measured flag, calibrated lens, base visible) | **1.55%** | **3.1 → 95% ±6 yd** |
| Unknown flag height, uncalibrated lens | 7.5% | 95% ±30 yd |

Conclusions:
- **The flag height dominates.** Flagsticks are not all the same height: 7 ft and 8 ft are both
  common, and a 1-inch error is 2.4 yd at 200 yd. Without a measured height for the course,
  Method A cannot reach ±5 yd. The app treats height uncertainty as an input and refuses to report
  a number when the total is too large.
- **Whether the base is visible is the next biggest term.** From a standing eye height, the green's
  front edge, the cup lip or long grass can hide the bottom inch or more. The ±1 in figure is a
  placeholder; the field test will show the real value.
- Pixel precision is not the limit at 200 yd *if* the detector finds the right top and base. The
  hard part is finding them (section 5).
- Heat shimmer moves each edge by roughly 0.1 px (cool, overcast) to 2.4 px (hot, low over grass)
  per frame at 200 yd, from the standard angle-of-arrival formula. Averaging many frames (Method C)
  reduces this.

## 3. Method B: two-position triangulation (judged impractical)

Step sideways by a baseline *b* and measure the parallax angle *θ ≈ b / D*. For 1σ = 2 yd at 200 yd,
*θ* must be known to 1.09%:

| Baseline | Parallax | Angle precision needed | Baseline precision needed |
|---|---|---|---|
| 0.5 m | 2.7 mrad (38 px) | 27 µrad (0.0016°) | 0.5 cm |
| 1 m | 5.5 mrad (76 px) | 55 µrad (0.0031°) | 1.1 cm |
| 2 m | 10.9 mrad | 109 µrad (0.0063°) | 2.2 cm |
| 10 m | 55 mrad | 547 µrad (0.031°) | 11 cm |
| 30 m | 164 mrad | 1.6 mrad (0.094°) | 33 cm |

The parallax itself is easy to see in pixels. What kills the method is the **change in camera
orientation between the two shots**, which adds directly to the measured angle and has to be known
to the same precision:
- **Gyroscope:** integrated orientation drifts by tenths of a degree over a few seconds of walking:
  10–100× too much for a 1–2 m baseline.
- **ARKit / visual-inertial tracking:** best case about 0.1°, which needs a baseline of at least
  29 m (32 yd), measured to ±30 cm. ARKit also runs only on the wide camera, not the 5× telephoto.
- **Distant background as an orientation reference:** only works if the background is effectively
  at infinity. Trees behind a green are usually 1.2–4× the pin distance; using trees at 2× the pin
  distance as the reference reads 400 yd for a 200 yd pin. The background distance is unknown, so
  the error is unbounded.
- **Structure-from-motion** solves for rotation and translation together, but needs many matched
  features at varied depths around the pin, a known scale (the baseline again), and still breaks
  down when every feature is at roughly the same depth, as on a golf hole.

**Recommendation: do not build Method B.** A second camera position would only help with a long,
precisely measured baseline (tens of metres, measured to centimetres) and an independent rotation
reference, which isn't practical for a golfer.

## 4. Method C: multi-frame computer vision

Method C is Method A run on every frame of a one-second, 30-frame burst. Each frame is resampled
along gravity and the stick is re-detected and tracked from frame to frame. The per-frame distances
are combined with a median, and outliers beyond 3.5 robust σ are dropped.

What it fixes:
- Random errors: shimmer, sensor noise, hand shake, sub-pixel jitter. These shrink roughly as
  1/√n_eff. The app assumes n_eff = n/3 because consecutive frames are correlated; the
  repeatability test checks that assumption.
- It **measures** the random error from the frame scatter rather than modelling it, so a shaky or
  shimmering burst correctly gets a wider range.

What it cannot fix:
- Systematic errors: wrong flag height, hidden base, focal-length error, or the detector
  consistently choosing the wrong top. **A stable wrong answer stays wrong.**

AI monocular depth estimation is not used. It predicts relative depth from learned cues and is not
a physical measurement; at 200 yd, its errors would be much larger than the target.

## 5. Detector test on synthetic images (and a bug fixed)

The flagstick detector came from the web prototype. I ported it to Swift and checked the port by
running the original JavaScript and a line-by-line Python mirror of the Swift on the same 30
synthetic 5× telephoto scenes. The outputs were identical.

The same tests showed the **original detector failing on textured (tree) backgrounds**. Its top
ran up into the tree texture by hundreds of pixels, giving errors of 100–700 yd from 100 yd out.
Against plain sky it was accurate. Changes made in the Swift version:
1. Stick strength is measured just above the base, instead of as a median over a run that may be
   mostly tree texture.
2. The top is found by walking up from the base along a polarity-consistent profile. A stick has a
   consistent polarity against its background; texture does not.
3. Extending the top through the flag cloth requires a cloth-like edge (one column, consistent
   polarity, ≥ 85% of rows) and a flag-sized length (6–30% of the stick).
4. A limp flag wrapped around the stick top is handled: a uniform patch, wider than the stick and
   ending in a clear change.

Synthetic results after the changes. There were 27 scenes per distance: trees/sky backgrounds,
flag/no flag/wrapped flag, a dim stick, heavy blur and noise.

| Distance | Stick found | Gross errors (> 5 yd) | Median abs error | 90th percentile |
|---|---|---|---|---|
| 50 yd | 27/27 | 2 | 0.05 yd | 0.6 yd |
| 100 yd | 26/27 | 4 | 0.35 yd | 17 yd |
| 150 yd | 24/27 | 5 | 0.7 yd | 11 yd |
| 200 yd | 25/27 | 11 | 2.3 yd | 38 yd |
| 250 yd | 23/27 | 4 | 1.5 yd | 20 yd |

These scenes were made deliberately hard. Real images will differ in both directions. The lessons
for the prototype:
- When the detector finds the right edges, sub-pixel accuracy is real (median errors well under
  1 yd before flag-height and calibration terms).
- **Gross errors still happen** on textured backgrounds and with low-contrast sticks (a white stick
  against bright sky), and the reported uncertainty does not catch them, because they repeat across
  frames. That's why the result screen shows the frozen frame with the lines for checking, and why
  the log records whether the lines were checked.

## 6. Assessment

| Question | Answer |
|---|---|
| Can the iPhone 16 Pro Max physically achieve ±3–5 yd at 200 yd? | **Only at the edge, and only with a measured flag height.** The physics floor is about ±6 yd (95%) at 200 yd with a tape-measured stick, a calibrated lens and a visible base. ±3 yd would need the base and height known to well under an inch. ±5 yd at 150 yd and in is more plausible. |
| Which techniques are realistic? | Method A with multi-frame averaging (Method C), plus a manual line check. |
| What limits come from optics and sensor? | About 13 mm per pixel at 200 yd, diffraction blur of about 2 px, and 1–2 cm sticks that are only 1 px wide. These limit *detection* more than *precision*. |
| Is a second camera position needed? | No. It doesn't help unless the baseline is tens of metres and precisely measured. |
| What extra calibration or user input is needed? | (1) A tape-measured visible flag height for each course, or a confirmed standard. (2) A one-time field calibration of the focal length on an object at a taped distance. (3) Holding steady for one second. (4) Checking the detected lines. |
| What accuracy can we expect, subject to testing? | 50–100 yd: about ±1–3 yd (95%) if the height is known. 150 yd: about ±3–5 yd. 200 yd: about ±6–8 yd. 250 yd: about ±8–12 yd. With an unknown flag height, the app should refuse beyond about 100 yd. |

**Recommended path: Method C (known height, multi-frame) as primary, with Method A single-frame
and manual lines logged alongside for comparison.** It is the only method whose error sources can
each be measured and reduced. The deciding question is not camera precision but whether the flag
height and the base location can be known well enough in practice. The field test is designed to
answer that.

Scripts behind these numbers: `docs/analysis/` (`budget.py`, `geomcheck.py`, synthetic detector
tests).
