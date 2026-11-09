import Foundation
import CoreVideo
import CoreGraphics

/// Everything needed to turn a position in a gravity-aligned ROI into a physical angle.
///
/// Coordinate conventions
/// - Buffer coordinates: the camera's native (landscape) pixel buffer, continuous, origin at the
///   top-left corner, pixel i covering [i, i+1). We never rotate the buffer, so the camera
///   intrinsics apply directly.
/// - ROI coordinates (u, v): u across the stick (to the right as the golfer sees it), v down
///   along gravity. The ROI is resampled so that a plumb flagstick is vertical regardless of
///   how the phone is rolled.
/// - Device frame (Core Motion): x right, y up (portrait), z out of the screen.
///   For the back camera, buffer +x = device -y and buffer +y = device -x; the optical axis is
///   device -z. So the world "up" vector in camera coordinates is (gy, gx, gz), where g is the
///   unit gravity vector reported by Core Motion (pointing toward the ground).
struct FrameGeometry: Codable {
    var originX: Double, originY: Double      // buffer point that ROI point (anchorU, anchorV) maps to
    var anchorU: Double, anchorV: Double
    var upX: Double, upY: Double              // unit "up" direction in buffer coordinates
    var roiW: Int, roiH: Int
    var fx: Double, fy: Double, cx: Double, cy: Double   // as delivered by the camera (unscaled)
    var gx: Double, gy: Double, gz: Double    // unit gravity, device frame
    var bufferW: Int, bufferH: Int

    var rightX: Double { -upY }
    var rightY: Double { upX }
    var downX: Double { -upX }
    var downY: Double { -upY }

    /// Pitch of the optical axis above the horizon, degrees.
    var pitchDeg: Double { asin(max(-1, min(1, gz))) * 180 / .pi }
    /// Roll of the phone around the optical axis, degrees (0 = upright portrait).
    var rollDeg: Double { atan2(gx, -gy) * 180 / .pi }

    func bufferPoint(u: Double, v: Double) -> (x: Double, y: Double) {
        let du = u - anchorU, dv = v - anchorV
        return (originX + du * rightX + dv * downX, originY + du * rightY + dv * downY)
    }

    func roiPoint(x: Double, y: Double) -> (u: Double, v: Double) {
        let dx = x - originX, dy = y - originY
        return (anchorU + dx * rightX + dy * rightY, anchorV + dx * downX + dy * downY)
    }

    /// Elevation angle (radians) of the ray through buffer point (x, y), using focal length
    /// scaled by the field-calibration factor k.
    func elevation(x: Double, y: Double, k: Double) -> Double {
        let rx = (x - cx) / (k * fx), ry = (y - cy) / (k * fy)
        let n = sqrt(rx * rx + ry * ry + 1)
        let s = (rx * gy + ry * gx + gz) / n
        return asin(max(-1, min(1, s)))
    }

    /// Horizontal distance (metres) to a plumb stick of visible height `heightM` whose top and
    /// base are at the given ROI positions: X = H / (tan(e_top) - tan(e_base)).
    func horizontalDistance(topU: Double, topV: Double, baseU: Double, baseV: Double,
                            heightM: Double, k: Double) -> Double? {
        let t = bufferPoint(u: topU, v: topV), b = bufferPoint(u: baseU, v: baseV)
        let eT = elevation(x: t.x, y: t.y, k: k), eB = elevation(x: b.x, y: b.y, k: k)
        let den = tan(eT) - tan(eB)
        guard den > 1e-7, den.isFinite else { return nil }
        return heightM / den
    }

    /// Build a geometry whose ROI puts the aim point 30% of the way down (the golfer aims at the
    /// flag, so most of the stick is below the aim point).
    static func make(aimX: Double, aimY: Double, gravity g: SIMD3<Double>, roiW: Int, roiH: Int,
                     fx: Double, fy: Double, cx: Double, cy: Double, bufferW: Int, bufferH: Int) -> FrameGeometry? {
        let n = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
        guard n > 0.1 else { return nil }
        let gx = g.x / n, gy = g.y / n, gz = g.z / n
        let ip = sqrt(gx * gx + gy * gy)            // how much of gravity lies in the image plane
        guard ip > 0.5 else { return nil }          // phone pointing too far up/down
        return FrameGeometry(originX: aimX, originY: aimY,
                             anchorU: Double(roiW) / 2, anchorV: Double(roiH) * 0.3,
                             upX: gy / ip, upY: gx / ip, roiW: roiW, roiH: roiH,
                             fx: fx, fy: fy, cx: cx, cy: cy, gx: gx, gy: gy, gz: gz,
                             bufferW: bufferW, bufferH: bufferH)
    }
}

/// A resampled, gravity-aligned patch of the camera image: luma (Y) and a chroma-strength
/// channel (C, roughly max(RGB) - min(RGB)), both 0...255 floats.
struct ROIImage {
    var Y: [Float]
    var C: [Float]
    var w: Int
    var h: Int
}

enum ROISampler {
    /// Bilinear resampling from a bi-planar 4:2:0 buffer (420f / 420v).
    static func sample(_ pb: CVPixelBuffer, geo: FrameGeometry) -> ROIImage? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yW = CVPixelBufferGetWidthOfPlane(pb, 0), yH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cW = CVPixelBufferGetWidthOfPlane(pb, 1), cH = CVPixelBufferGetHeightOfPlane(pb, 1)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let yp = yb.assumingMemoryBound(to: UInt8.self)
        let cp = cb.assumingMemoryBound(to: UInt8.self)
        let w = geo.roiW, h = geo.roiH
        var Y = [Float](repeating: 0, count: w * h)
        var C = [Float](repeating: 0, count: w * h)

        // ROI sample (c, r) has its centre at ROI point (c + 0.5, r + 0.5).
        let p0 = geo.bufferPoint(u: 0.5, v: 0.5)
        let rx = geo.rightX, ry = geo.rightY, dx = geo.downX, dy = geo.downY

        @inline(__always) func lum(_ x: Double, _ y: Double) -> Float {
            let fxp = min(max(x - 0.5, 0), Double(yW - 1) - 0.001)
            let fyp = min(max(y - 0.5, 0), Double(yH - 1) - 0.001)
            let ix = Int(fxp), iy = Int(fyp)
            let ax = Float(fxp - Double(ix)), ay = Float(fyp - Double(iy))
            let o = iy * yBPR + ix
            let v00 = Float(yp[o]), v10 = Float(yp[o + 1])
            let v01 = Float(yp[o + yBPR]), v11 = Float(yp[o + yBPR + 1])
            return (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
        }
        @inline(__always) func chromaAt(_ ix: Int, _ iy: Int) -> Float {
            let o = iy * cBPR + ix * 2
            let u = abs(Float(cp[o]) - 128), v = abs(Float(cp[o + 1]) - 128)
            return 2 * max(u, v)
        }
        @inline(__always) func chroma(_ x: Double, _ y: Double) -> Float {
            let fxp = min(max(x / 2 - 0.5, 0), Double(cW - 1) - 0.001)
            let fyp = min(max(y / 2 - 0.5, 0), Double(cH - 1) - 0.001)
            let ix = Int(fxp), iy = Int(fyp)
            let ax = Float(fxp - Double(ix)), ay = Float(fyp - Double(iy))
            let v00 = chromaAt(ix, iy), v10 = chromaAt(ix + 1, iy)
            let v01 = chromaAt(ix, iy + 1), v11 = chromaAt(ix + 1, iy + 1)
            return (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
        }

        Y.withUnsafeMutableBufferPointer { Yp in
            C.withUnsafeMutableBufferPointer { Cp in
                for r in 0..<h {
                    var x = p0.x + Double(r) * dx, y = p0.y + Double(r) * dy
                    let o = r * w
                    for c in 0..<w {
                        Yp[o + c] = lum(x, y)
                        Cp[o + c] = chroma(x, y)
                        x += rx; y += ry
                    }
                }
            }
        }
        return ROIImage(Y: Y, C: C, w: w, h: h)
    }

    /// Grayscale image of (part of) the ROI for display, contrast-stretched.
    static func makeImage(_ roi: ROIImage, crop: CGRect? = nil) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: roi.w, height: roi.h)
        let r = (crop ?? full).intersection(full).integral
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        var vals: [Float] = []
        vals.reserveCapacity(w * h / 9 + 1)
        var yy = y0
        while yy < y0 + h { var xx = x0; while xx < x0 + w { vals.append(roi.Y[yy * roi.w + xx]); xx += 3 }; yy += 3 }
        vals.sort()
        let lo = vals.isEmpty ? 0 : vals[Int(Double(vals.count - 1) * 0.01)]
        let hi = vals.isEmpty ? 255 : vals[Int(Double(vals.count - 1) * 0.99)]
        let scale: Float = hi > lo ? 255 / (hi - lo) : 1
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = (roi.Y[(y0 + y) * roi.w + x0 + x] - lo) * scale
                bytes[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
