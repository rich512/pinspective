import AVFoundation
import CoreMedia
import simd
import UIKit

/// One camera frame plus the metadata needed to measure from it.
struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let time: Double
    let width: Int
    let height: Int
    let fx: Double, fy: Double, cx: Double, cy: Double
    let intrinsicsSource: String
    let iso: Float
    let exposureS: Double
    let lensPosition: Float
}

struct CameraInfo {
    var deviceName = "—"
    var deviceType = "—"
    var isTelephoto = false
    var uniqueKey = ""            // camera + format, used to key lens calibrations
    var width = 0
    var height = 0
    var fovDeg = 0.0
    var fxFromFOV = 0.0
    var fxIntrinsic: Double? = nil
    var cxIntrinsic: Double? = nil
    var cyIntrinsic: Double? = nil
    var intrinsicsDelivery = false
    var stabilization = "—"
    var distortionCorrection = "—"
    var zoomFactor = 1.0
}

/// AVFoundation capture: 5× telephoto, highest-resolution 4:2:0 format at 30 fps, no digital
/// zoom, no video stabilisation (stabilisation crops and warps the image, which would make the
/// camera intrinsics wrong), and per-frame intrinsic matrix delivery when the device supports it.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "pinspective.video", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "pinspective.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    private var configured = false
    private var fxFOV = 0.0
    private var formatW = 0
    private var lastInfoPush = 0.0

    @Published var state = "Starting camera…"
    @Published var ready = false
    @Published var info = CameraInfo()
    @Published var focusLocked = false

    /// Called on `videoQueue` for every frame.
    var onFrame: ((CameraFrame) -> Void)?

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    private func publish(_ s: String, ready r: Bool = false) {
        DispatchQueue.main.async { self.state = s; self.ready = r }
    }

    private func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { g in granted = g; sem.signal() }
            sem.wait()
            guard granted else { publish("Camera access denied. Enable it in Settings › PinSpective."); return }
        default:
            publish("Camera access denied. Enable it in Settings › PinSpective.")
            return
        }

        let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        guard let dev = tele ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            publish("No rear camera found (the Simulator has no camera; run on the iPhone).")
            return
        }
        device = dev

        session.beginConfiguration()
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            publish("Could not open the camera.")
            return
        }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            publish("Could not attach the video output.")
            return
        }
        session.addOutput(videoOutput)

        var inf = CameraInfo()
        inf.deviceName = dev.localizedName
        inf.deviceType = dev.deviceType.rawValue
        inf.isTelephoto = dev.deviceType == .builtInTelephotoCamera

        if let fmt = Self.bestFormat(dev) {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                if fmt.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    let d = CMTime(value: 1, timescale: 30)
                    dev.activeVideoMinFrameDuration = d
                    dev.activeVideoMaxFrameDuration = d
                }
                dev.videoZoomFactor = 1.0     // optical only: never use digital zoom for measurement
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.unlockForConfiguration()
            } catch {
                // keep the default format
            }
        }

        if let c = videoOutput.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isCameraIntrinsicMatrixDeliverySupported { c.isCameraIntrinsicMatrixDeliveryEnabled = true }
            inf.intrinsicsDelivery = c.isCameraIntrinsicMatrixDeliveryEnabled
            inf.stabilization = c.isVideoStabilizationSupported ? "off" : "not supported"
        }
        session.commitConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        formatW = Int(dims.width)
        inf.width = Int(dims.width)
        inf.height = Int(dims.height)
        inf.fovDeg = Double(dev.activeFormat.videoFieldOfView)
        fxFOV = Double(dims.width) / 2 / tan(inf.fovDeg / 2 * .pi / 180)
        inf.fxFromFOV = fxFOV
        inf.zoomFactor = Double(dev.videoZoomFactor)
        inf.distortionCorrection = dev.isGeometricDistortionCorrectionSupported
            ? (dev.isGeometricDistortionCorrectionEnabled ? "on" : "off") : "not supported"
        inf.uniqueKey = "\(dev.uniqueID)|\(dims.width)x\(dims.height)"
        let readyText = inf.isTelephoto
            ? "Telephoto \(dims.width)×\(dims.height)"
            : "Telephoto camera not available — using \(dev.localizedName)"
        DispatchQueue.main.async {
            self.info = inf
            self.state = readyText
            self.ready = true
        }
        configured = true
    }

    /// Highest-resolution bi-planar 4:2:0 format that can run at 30 fps.
    static func bestFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let full = CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return Double(d.width) * Double(d.height) + (full ? 1 : 0) - (f.isVideoBinned ? 2 : 0)
        }
        let ok = dev.formats.filter { f in
            let st = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return (st == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || st == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 }
        }
        return ok.max { score($0) < score($1) }
    }

    // MARK: focus

    /// Focus and expose at a point given in capture-device coordinates (0...1, landscape).
    func focus(at p: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p }
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.unlockForConfiguration()
                DispatchQueue.main.async { self.focusLocked = false }
            } catch {}
        }
    }

    /// Lock focus at the current lens position (so focus hunting can't change the focal length mid-burst).
    func setFocusLocked(_ lock: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if lock, d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                else if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
                DispatchQueue.main.async { self.focusLocked = lock }
            } catch {}
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let scaleW = formatW > 0 ? Double(w) / Double(formatW) : 1
        var fx = fxFOV * scaleW, fy = fx, cx = Double(w) / 2, cy = Double(h) / 2
        var src = "format-FOV"

        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            var m = matrix_float3x3()
            withUnsafeMutableBytes(of: &m) { raw in _ = data.copyBytes(to: raw) }
            var mfx = Double(m.columns.0.x), mfy = Double(m.columns.1.y)
            var mcx = Double(m.columns.2.x), mcy = Double(m.columns.2.y)
            if mfx.isFinite, mfx > 100, mfy.isFinite, mfy > 100, mcx > 0, mcy > 0 {
                src = "intrinsic-matrix"
                // The matrix should be in this buffer's pixels; if its principal point says otherwise,
                // rescale and flag it so the CSV shows what happened.
                let s = Double(w) / 2 / mcx
                if s < 0.75 || s > 1.33 {
                    mfx *= s; mfy *= s; mcx *= s; mcy *= s
                    src = "intrinsic-matrix-rescaled"
                }
                fx = mfx; fy = mfy; cx = mcx; cy = mcy
            }
        }

        let d = device
        let frame = CameraFrame(pixelBuffer: pb,
                                time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
                                width: w, height: h, fx: fx, fy: fy, cx: cx, cy: cy,
                                intrinsicsSource: src,
                                iso: d?.iso ?? 0,
                                exposureS: d?.exposureDuration.seconds ?? 0,
                                lensPosition: d?.lensPosition ?? 0)

        // Occasionally publish the live intrinsics for the diagnostics screen.
        if frame.time - lastInfoPush > 1 {
            lastInfoPush = frame.time
            let isMatrix = src.hasPrefix("intrinsic")
            DispatchQueue.main.async {
                self.info.fxIntrinsic = isMatrix ? fx : nil
                self.info.cxIntrinsic = isMatrix ? cx : nil
                self.info.cyIntrinsic = isMatrix ? cy : nil
            }
        }
        onFrame?(frame)
    }
}
