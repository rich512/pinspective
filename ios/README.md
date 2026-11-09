# PinSpective iOS: camera distance prototype

A native iPhone app for one job: test whether the iPhone 16 Pro Max 5× telephoto can measure the
distance to a flagstick. There is no GPS, no course maps, no internet and no laser hardware. If the
app can't calculate a defensible distance, it shows **"Measurement unavailable"**.

The web app (`../index.html`) is unchanged and still works. This folder is separate.

Before trusting any number, read `../docs/FEASIBILITY.md`: what is physically possible, why
two-position triangulation was not built, and the detector problems found in testing.

## What's in the app

| # | Requirement | Where |
|---|---|---|
| 1 | Live camera view | `Camera/CameraPreview.swift` (aspect-fit, full optical field) |
| 2 | 5× telephoto | `Camera/CameraManager.swift`: `.builtInTelephotoCamera`, highest-res 4:2:0 format at 30 fps, zoom factor fixed at 1.0 (no digital zoom), stabilisation off, per-frame intrinsic matrix |
| 3 | Targeting and lock | Tap the stick, or press **Lock** to lock at the reticle. The stick is tracked frame to frame. A loupe shows the analysed region with red (top) and blue (base) lines |
| 4 | Capture | **Measure** captures a 30-frame (1 s) burst |
| 5–7 | Distance, 95% range, method | Result screen |
| 8–9 | Laser distance, error | Result screen and Log (editable later) |
| 10 | CSV export | Log › share icon. Also in the Files app under PinSpective (`measurements.json`) |
| | Manual target selection | Tap to choose the stick. On the result screen, drag the lines or nudge them 0.25 px at a time |
| | Lens calibration | **Calibrate**: object of known height at a tape-measured distance |
| | Accuracy stats | **Stats**: MAE, median error, 90th percentile, bias, RMS, 95%-range coverage, repeatability, success rate, time to result; by distance, lighting, background, flag type and method |

### Project layout

```
ios/
  PinSpective.xcodeproj         Xcode 16 project (folder-synchronised: new files are picked up automatically)
  PinSpective/
    PinSpectiveApp.swift        app entry, shared objects
    Camera/                     AVFoundation capture, preview + overlay, Core Motion gravity
    Vision/                     gravity-aligned ROI sampling, geometry, flagstick detector
    Core/                       distance estimator + uncertainty, burst engine, settings, log/CSV, stats
    Views/                      SwiftUI screens
```

Frameworks: SwiftUI, AVFoundation, CoreMedia, CoreVideo, CoreMotion, simd. No third-party code.
Apple's Vision framework isn't used: it has no flagstick detector, and its general-purpose detectors
don't give the sub-pixel top/base edges this measurement needs. The detector is classical computer
vision, ported from the web prototype and fixed (see FEASIBILITY.md §5).

Permissions (set in the build settings, nothing to add by hand): camera
(`NSCameraUsageDescription`) and motion (`NSMotionUsageDescription`). File sharing is on so the
log shows up in the Files app.

## Install on your iPhone 16 Pro Max

You need a Mac with **Xcode 16 or newer** and a free Apple ID. No paid developer account is needed
for your own phone.

1. Get the code on the Mac: `git clone https://github.com/rich512/pinspective` (or download the
   ZIP), then open `ios/PinSpective.xcodeproj`.
2. In Xcode, click the **PinSpective** project, then the **PinSpective** target, then **Signing &
   Capabilities**:
   - Tick **Automatically manage signing**.
   - **Team**: add your Apple ID (Xcode › Settings › Accounts) and pick your "Personal Team".
   - **Bundle Identifier**: change `com.example.pinspective` to something unique, e.g.
     `ca.thegordonbrothers.pinspective`.
3. On the iPhone, turn on **Settings › Privacy & Security › Developer Mode** and restart when asked.
4. Connect the iPhone by cable, unlock it and tap **Trust**. Choose it as the run destination at
   the top of the Xcode window.
5. Press **⌘R**. The first build takes a minute or two.
6. If the phone says "Untrusted Developer": **Settings › General › VPN & Device Management**, then
   trust your Apple ID.
7. Allow camera and motion access on first launch.

With a free Personal Team, the app expires after 7 days. Press ⌘R again to reinstall; the log is kept.

The project was written and reviewed without access to Xcode (the cloud workspace runs Linux).
`.github/workflows/ios-build.yml` compiles it on a GitHub macOS runner when `ios/` is pushed. If
Xcode reports errors, paste them back and they can be fixed quickly.

## How each distance is calculated

**Image geometry.** The camera's native landscape buffer is never rotated, so the intrinsics
(fx, fy, cx, cy) from `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` apply directly. Core
Motion gravity *g* (device frame) gives the world "up" direction in camera coordinates as
*(g_y, g_x, g_z)*. A 320 × 1280 px region around the aim point is resampled bilinearly along
gravity, so a plumb flagstick is vertical whatever the phone's roll. Measurements stay in
full-resolution sensor pixels; nothing is digitally zoomed.

**Detection** (`Vision/StickDetector.swift`): a thin-line (ridge) filter on luma and chroma, robust
noise threshold, best vertical run per column, then the top is found by walking up from the base.
Flag-cloth and wrapped-flag handling, then sub-pixel edges where the profile crosses half level.

**Method A (known height, one frame).** For the detected top and base, compute each pixel's ray
and its elevation angle *e*, then

  `X = H / (tan e_top − tan e_base)`  (horizontal distance; exact for a plumb stick at any pitch)

*H* = the visible flagstick height you set (green surface to top of stick). The focal length is
`k · fx`, where *k* is the field-calibration factor (1.0 until calibrated).

**Method C (multi-frame).** Method A on every frame of the burst, outliers beyond 3.5 robust σ
dropped, median taken. Random error = robust frame scatter ÷ √(n/3) (consecutive frames are
assumed correlated), with a floor of 0.25 px per edge.

**Manual.** Method A with your adjusted lines on the frozen frame (0.75 px per edge).

**Uncertainty** (1σ, relative, combined in quadrature):

| Term | Value |
|---|---|
| Image | Method C: measured scatter. Method A: modelled 0.5 px per edge |
| Flag height | your ± ÷ H (default 6 in ÷ 84 in = 7%) |
| Base location | your ± ÷ H (default 1 in ÷ 84 in = 1.2%) |
| Focal length | calibrated k uncertainty (≥ 0.3%), or 2% uncalibrated |

The app shows *X* ± 1.96σ. It shows **Measurement unavailable** if the stick is in fewer than 50%
of frames, under 25 px tall, or the 95% half-width exceeds the limit (default ±10%). The reason is
shown and logged. The raw number is kept in the CSV for analysis but never displayed.

**Lens calibration.** For each frame, *k* is found by bisection so that the computed distance equals
the tape-measured distance. The median over frames is used, with an uncertainty from frame scatter,
pixel floor, and object-height and distance uncertainties. Several calibrations are combined by
inverse-variance weighting, and the uncertainty is inflated if they disagree.

What was reused from the web prototype: the flagstick detector (fixed), the top/base angle formula,
and the idea of lens calibration and confidence ranges. What was left out on purpose: GPS
walk-off tuning, maps, weather, plays-like, slope and club suggestions.

## Real-world test procedure

**Equipment:** the iPhone, a laser rangefinder (the ground truth; take the median of three
readings and note its spec, typically ±1 yd), a 100 ft tape measure, and ideally a range or quiet
course with pins you can walk to.

### Phase 0: setup (once per course)
1. **Measure the visible flag height** at each test pin with the tape: putting surface to the top
   of the stick (not the flag). In Settings, enter the height and set **± to 0.5 in**. Note the
   flagstick type (e.g. "8 ft yellow fiberglass").
2. **Calibrate the lens** three times on a target **not** used in the accuracy test: a flagstick or
   painted pole on flat ground at a **tape-measured** 30–50 yd (e.g. 100.0 ft ± 0.25 ft). Lock
   focus (lock icon), press **Calibrate**, enter the values, aim, press **Capture**, check the
   lines, save. The three *k* values should agree within about 0.5%. If not, find out why before
   going on.
3. In Settings › Test conditions, set lighting, background and flagstick type, and update them
   whenever they change.

### Phase 1: accuracy at fixed distances
At about **50, 100, 150, 200 and 250 yd** from a pin (lasered; real distances need not be round):
1. Set the station label (e.g. `P3-200`).
2. Stand still. Brace your elbows if you can, and note "braced" or "handheld" in Notes.
3. Tap the stick (or reticle + Lock). Wait for green lines. Press **Measure** and hold steady for 1 s.
4. On the result screen, check the lines and set **Detected lines** to Correct or Wrong. Enter the
   laser distance. **Save every attempt**, including "unavailable" ones.
5. Unlock, re-aim and repeat: **10 attempts per station**.

### Phase 2: conditions
Repeat 150 yd and 200 yd (10 attempts each) in: full sun, overcast, backlit / low sun; pins in front
of trees vs sky; at least two flagstick types; a calm (wrapped flag) and a windy day; and around
midday heat (shimmer) vs morning.

### Phase 3: analysis
Open **Stats**, or export the CSV (Log › share) for a spreadsheet. Things to look at:

| Metric | What it tells you |
|---|---|
| Success rate per distance | how often a defensible number is produced |
| MAE, median error, 90th percentile abs error | the accuracy question; the ±3–5 yd at 200 yd goal is judged on P90 |
| Bias vs distance | a bias proportional to distance means a focal or height error; reading long consistently suggests a hidden base |
| Inside 95% range | should be about 95%. Much lower means the uncertainty model is too optimistic; widen the base or height terms |
| Repeatability | spread of repeat readings at one station; compare it with the reported σ |
| A vs C vs manual | whether multi-frame and manual lines actually help |
| lines_check = wrong | how often the automatic detector fails, by background and lighting |

Suggested pass mark for this phase (the decision is yours): at 200 yd, P90 abs error ≤ 5 yd,
95%-range coverage ≥ 90%, and success rate ≥ 80%, across at least 50 attempts in two lighting
conditions.
