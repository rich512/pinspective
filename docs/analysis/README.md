# Analysis scripts

Python 3 with numpy and scipy.

- `budget.py`: optics, error budget, shimmer and triangulation numbers in FEASIBILITY.md.
- `geomcheck.py`: simulates a pitched, rolled phone and checks that the Swift geometry
  (gravity → ROI axes → elevation angles → distance) recovers the true distance.
- `synth.py`: renders synthetic gravity-aligned 5× telephoto ROIs (stick, flag, wrapped flag,
  trees or sky, blur, noise).
- `detector_mirror.py`: line-by-line Python mirror of `ios/PinSpective/Vision/StickDetector.swift`.
  Set `TRIM=False` to get the original web-app detector, which this mirror reproduced exactly
  against the JavaScript.
- `eval_detector.py [walk_fraction]`: distance error (yd) per scene type and distance.
