import Foundation
import CoreGraphics
import QuartzCore

enum BurstPurpose {
    case measure
    case calibrate(heightM: Double, sigmaHeightM: Double, distanceM: Double, sigmaDistanceM: Double)
}

/// The finished analysis of one burst, handed to the result screen.
struct BurstResult: Identifiable {
    let id = UUID()
    var frames: [FrameSample]
    var reviewIndex: Int?            // frame shown for review / manual lines
    var reviewROI: ROIImage?
    var cfg: EstimateConfig
    var single: MethodEstimate       // Method A
    var multi: MethodEstimate        // Method C
    var cameraName: String
    var cameraKey: String
    var focalK: Double
    var focalKSigma: Double
    var calibrationCount: Int
    var focusLocked: Bool
    var timeToResultS: Double
    var burstDurationS: Double
    var pitchJitterDeg: Double
}

struct CalibrationOutcome: Identifiable {
    let id = UUID()
    var k: Double?
    var sigmaK: Double?
    var framesUsed: Int
    var framesTotal: Int
    var spanPx: Double?
    var fxReported: Double
    var intrinsicsSource: String
    var message: String
}

/// Drives everything that happens per frame: target tracking, the live overlay, and burst
/// capture. All mutable tracking state lives on the camera's video queue; results are published
/// on the main queue.
final class MeasurementEngine: ObservableObject {
    static let roiW = 320
    static let roiH = 1280

    @Published var locked = false
    @Published var overlay: LiveOverlay?
    @Published var loupe: CGImage?
    @Published var loupeLines: (top: Double, base: Double, x: Double)?   // as fractions of the loupe image
    @Published var liveText = ""
    @Published var rollDeg = 0.0
    @Published var pitchDeg = 0.0
    @Published var capturing = false
    @Published var progress = 0.0
    @Published var burstResult: BurstResult?
    @Published var calibrationOutcome: CalibrationOutcome?
    @Published var lostMessage: String?

    let camera: CameraManager
    let motion: MotionManager

    private final class Burst {
        var purpose: BurstPurpose
        var cfg: EstimateConfig
        var target: Int
        var frames: [FrameSample] = []
        var reviewROI: ROIImage?
        var reviewIndex: Int?
        var lastROI: ROIImage?
        var lastIndex: Int?
        var pitches: [Double] = []
        var startTime: Double
        var meta: (name: String, key: String, k: Double, sigK: Double, count: Int, focusLocked: Bool)
        init(purpose: BurstPurpose, cfg: EstimateConfig, target: Int, startTime: Double,
             meta: (name: String, key: String, k: Double, sigK: Double, count: Int, focusLocked: Bool)) {
            self.purpose = purpose; self.cfg = cfg; self.target = target; self.startTime = startTime; self.meta = meta
        }
    }

    // video-queue state
    private var aim: CGPoint?
    private var isLocked = false
    private var misses = 0
    private var lockTime = 0.0
    private var burst: Burst?
    private var liveCfg: EstimateConfig?
    private var lastOverlayPub = 0.0, lastLoupePub = 0.0, lastOrientPub = 0.0
    private var bufW = 0, bufH = 0

    init(camera: CameraManager, motion: MotionManager) {
        self.camera = camera
        self.motion = motion
        camera.onFrame = { [weak self] f in self?.handle(f) }
    }

    // MARK: main-thread API

    func setLiveConfig(_ c: EstimateConfig) {
        camera.videoQueue.async { self.liveCfg = c }
    }

    /// Manual target selection: lock onto the flagstick near this buffer point.
    func lock(atBuffer p: CGPoint) {
        locked = true
        lostMessage = nil
        camera.videoQueue.async {
            self.aim = p; self.isLocked = true; self.misses = 0; self.lockTime = CACurrentMediaTime()
        }
    }

    /// Lock at the reticle (image centre).
    func lockAtCenter() {
        camera.videoQueue.async {
            guard self.bufW > 0 else { return }
            let p = CGPoint(x: Double(self.bufW) / 2, y: Double(self.bufH) / 2)
            DispatchQueue.main.async { self.lock(atBuffer: p) }
        }
    }

    func unlock() {
        locked = false
        overlay = nil
        loupe = nil
        loupeLines = nil
        liveText = ""
        camera.videoQueue.async { self.isLocked = false; self.aim = nil; self.burst = nil }
    }

    func startBurst(_ purpose: BurstPurpose, cfg: EstimateConfig, frames: Int,
                    meta: (name: String, key: String, k: Double, sigK: Double, count: Int, focusLocked: Bool)) {
        guard !capturing else { return }
        capturing = true
        progress = 0
        locked = true
        lostMessage = nil
        camera.videoQueue.async {
            let now = CACurrentMediaTime()
            if self.aim == nil || !self.isLocked {
                self.aim = CGPoint(x: Double(self.bufW) / 2, y: Double(self.bufH) / 2)
                self.lockTime = now
            }
            self.isLocked = true
            self.misses = 0
            self.burst = Burst(purpose: purpose, cfg: cfg, target: max(1, frames), startTime: now, meta: meta)
        }
    }

    // MARK: per-frame work (video queue)

    private func handle(_ f: CameraFrame) {
        bufW = f.width; bufH = f.height
        let now = CACurrentMediaTime()
        guard let g = motion.gravity() else { return }
        if now - lastOrientPub > 0.1 {
            lastOrientPub = now
            let roll = atan2(g.x, -g.y) * 180 / .pi
            let pitch = asin(max(-1, min(1, g.z / max(1e-6, sqrt(g.x * g.x + g.y * g.y + g.z * g.z))))) * 180 / .pi
            DispatchQueue.main.async { self.rollDeg = roll; self.pitchDeg = pitch }
        }
        guard (isLocked || burst != nil), let a = aim else { return }
        guard let geo = FrameGeometry.make(aimX: a.x, aimY: a.y, gravity: g,
                                           roiW: Self.roiW, roiH: Self.roiH,
                                           fx: f.fx, fy: f.fy, cx: f.cx, cy: f.cy,
                                           bufferW: f.width, bufferH: f.height) else { return }
        let t0 = CACurrentMediaTime()
        guard let roi = ROISampler.sample(f.pixelBuffer, geo: geo) else { return }
        let det = StickDetector.detect(Y: roi.Y, C: roi.C, w: roi.w, h: roi.h,
                                       seedX: geo.anchorU, seedY: geo.anchorV)
        let ms = (CACurrentMediaTime() - t0) * 1000
        let good = det?.ok == true

        // tracking: keep the aim point near the top of the stick from frame to frame
        if good, let d = det {
            let p = geo.bufferPoint(u: d.x, v: d.yTop + 0.15 * d.span)
            if p.x > 0, p.y > 0, p.x < Double(f.width), p.y < Double(f.height) { aim = CGPoint(x: p.x, y: p.y) }
            misses = 0
        } else {
            misses += 1
            if misses > 60 && burst == nil {
                isLocked = false; aim = nil
                DispatchQueue.main.async {
                    self.locked = false; self.overlay = nil; self.loupe = nil; self.loupeLines = nil
                    self.liveText = ""; self.lostMessage = "Lost the flagstick. Tap it or press Lock."
                }
                return
            }
        }

        if let b = burst {
            b.frames.append(FrameSample(geo: geo, det: det, time: f.time, intrinsicsSource: f.intrinsicsSource,
                                        iso: f.iso, exposureS: f.exposureS, lensPosition: f.lensPosition, processingMs: ms))
            b.pitches.append(geo.pitchDeg)
            if good {
                b.lastROI = roi; b.lastIndex = b.frames.count - 1
                if b.reviewROI == nil && b.frames.count >= b.target / 2 { b.reviewROI = roi; b.reviewIndex = b.frames.count - 1 }
            }
            let prog = Double(b.frames.count) / Double(b.target)
            DispatchQueue.main.async { self.progress = prog }
            if b.frames.count >= b.target {
                burst = nil
                finish(b, frame: f, now: CACurrentMediaTime())
            }
        }

        if now - lastOverlayPub > 1.0 / 15 {
            lastOverlayPub = now
            var o = LiveOverlay(bufferW: f.width, bufferH: f.height, aim: CGPoint(x: a.x, y: a.y), top: nil, base: nil, good: good)
            var text = good ? "" : "Searching for the flagstick…"
            if let d = det, d.span > 3 {
                let t = geo.bufferPoint(u: d.x, v: d.yTop), bt = geo.bufferPoint(u: d.x, v: d.yBot)
                o.top = CGPoint(x: t.x, y: t.y); o.base = CGPoint(x: bt.x, y: bt.y)
                if good, let cfg = liveCfg {
                    let one = DistanceEstimator.singleFrame([FrameSample(geo: geo, det: d, time: f.time, intrinsicsSource: f.intrinsicsSource,
                                                                         iso: f.iso, exposureS: f.exposureS, lensPosition: f.lensPosition,
                                                                         processingMs: ms)], cfg: cfg)
                    if one.available, let y = one.distanceYd, let h = one.halfWidth95Yd {
                        text = String(format: "Live single frame: %.0f ± %.0f yd · stick %.0f px", y, h, d.span)
                    } else {
                        text = String(format: "Stick %.0f px · live estimate unavailable", d.span)
                    }
                }
            }
            DispatchQueue.main.async { self.overlay = o; self.liveText = text }
        }
        if now - lastLoupePub > 0.2 {
            lastLoupePub = now
            let img = ROISampler.makeImage(roi)
            let lines: (top: Double, base: Double, x: Double)? = det.map {
                (top: $0.yTop / Double(roi.h), base: $0.yBot / Double(roi.h), x: $0.x / Double(roi.w))
            }
            DispatchQueue.main.async { self.loupe = img; self.loupeLines = lines }
        }
    }

    private func finish(_ b: Burst, frame f: CameraFrame, now: Double) {
        let pj = Stats.sd(b.pitches)
        switch b.purpose {
        case .measure:
            let a = DistanceEstimator.singleFrame(b.frames, cfg: b.cfg)
            let c = DistanceEstimator.multiFrame(b.frames, cfg: b.cfg)
            let r = BurstResult(frames: b.frames,
                                reviewIndex: b.reviewIndex ?? b.lastIndex,
                                reviewROI: b.reviewROI ?? b.lastROI,
                                cfg: b.cfg, single: a, multi: c,
                                cameraName: b.meta.name, cameraKey: b.meta.key,
                                focalK: b.meta.k, focalKSigma: b.meta.sigK, calibrationCount: b.meta.count,
                                focusLocked: b.meta.focusLocked,
                                timeToResultS: now - lockTime, burstDurationS: now - b.startTime,
                                pitchJitterDeg: pj)
            DispatchQueue.main.async { self.capturing = false; self.burstResult = r }
        case let .calibrate(h, sh, d, sd):
            let cal = DistanceEstimator.calibrate(b.frames, objectHeightM: h, objectSigmaM: sh, distanceM: d, distanceSigmaM: sd)
            let valid = b.frames.filter { $0.det?.ok == true }.count
            let out = CalibrationOutcome(k: cal?.k, sigmaK: cal?.sigma, framesUsed: cal?.n ?? 0, framesTotal: b.frames.count,
                                         spanPx: cal?.span, fxReported: f.fx, intrinsicsSource: f.intrinsicsSource,
                                         message: cal == nil
                                            ? "Calibration failed: the object was found in \(valid) of \(b.frames.count) frames (need 5), or the numbers imply an implausible lens. Check the lines and the inputs."
                                            : "")
            DispatchQueue.main.async { self.capturing = false; self.calibrationOutcome = out }
        }
    }
}
