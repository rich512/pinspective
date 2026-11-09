import SwiftUI
import AVFoundation

/// Lets SwiftUI code convert between screen points and capture-device coordinates.
final class PreviewBridge {
    weak var view: PreviewUIView?

    /// Screen point (in the preview's own coordinate space) -> buffer pixel coordinates.
    func bufferPoint(fromViewPoint p: CGPoint, bufferW: Int, bufferH: Int) -> CGPoint? {
        guard let v = view else { return nil }
        let d = v.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
        guard d.x >= 0, d.x <= 1, d.y >= 0, d.y <= 1 else { return nil }
        return CGPoint(x: d.x * CGFloat(bufferW), y: d.y * CGFloat(bufferH))
    }

    func devicePoint(fromViewPoint p: CGPoint) -> CGPoint? {
        view?.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
    }
}

/// What the live overlay should draw, in buffer pixel coordinates.
struct LiveOverlay: Equatable {
    var bufferW: Int
    var bufferH: Int
    var aim: CGPoint?
    var top: CGPoint?
    var base: CGPoint?
    var good: Bool
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let stickLayer = CAShapeLayer()
    private let topLayer = CAShapeLayer()
    private let baseLayer = CAShapeLayer()
    private let aimLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect   // show the full optical field; no crop
        for (l, c) in [(stickLayer, UIColor.systemGreen), (topLayer, UIColor.systemRed),
                       (baseLayer, UIColor.systemBlue), (aimLayer, UIColor.systemYellow)] {
            l.strokeColor = c.cgColor
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 2
            layer.addSublayer(l)
        }
        stickLayer.lineDashPattern = [4, 4]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90   // portrait
        }
        for l in [stickLayer, topLayer, baseLayer, aimLayer] { l.frame = bounds }
    }

    func draw(_ o: LiveOverlay?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let o else {
            for l in [stickLayer, topLayer, baseLayer, aimLayer] { l.path = nil }
            return
        }
        func pt(_ b: CGPoint) -> CGPoint {
            previewLayer.layerPointConverted(fromCaptureDevicePoint:
                CGPoint(x: b.x / CGFloat(o.bufferW), y: b.y / CGFloat(o.bufferH)))
        }
        if let a = o.aim {
            let p = pt(a)
            aimLayer.path = UIBezierPath(ovalIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)).cgPath
        } else { aimLayer.path = nil }
        if let t = o.top, let b = o.base {
            let pt1 = pt(t), pb = pt(b)
            let s = UIBezierPath(); s.move(to: pt1); s.addLine(to: pb)
            stickLayer.path = s.cgPath
            stickLayer.strokeColor = (o.good ? UIColor.systemGreen : UIColor.systemOrange).cgColor
            let tp = UIBezierPath(); tp.move(to: CGPoint(x: pt1.x - 16, y: pt1.y)); tp.addLine(to: CGPoint(x: pt1.x + 16, y: pt1.y))
            topLayer.path = tp.cgPath
            let bp = UIBezierPath(); bp.move(to: CGPoint(x: pb.x - 16, y: pb.y)); bp.addLine(to: CGPoint(x: pb.x + 16, y: pb.y))
            baseLayer.path = bp.cgPath
        } else {
            stickLayer.path = nil; topLayer.path = nil; baseLayer.path = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let bridge: PreviewBridge
    var overlay: LiveOverlay?

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView(frame: .zero)
        v.previewLayer.session = session
        bridge.view = v
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.setNeedsLayout()
        v.draw(overlay)
    }
}
