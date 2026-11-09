import SwiftUI

@main
struct PinSpectiveApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: MeasurementStore
    @StateObject private var camera: CameraManager
    @StateObject private var engine: MeasurementEngine
    private let motion: MotionManager

    init() {
        let cam = CameraManager()
        let mot = MotionManager()
        motion = mot
        _settings = StateObject(wrappedValue: AppSettings())
        _store = StateObject(wrappedValue: MeasurementStore())
        _camera = StateObject(wrappedValue: cam)
        _engine = StateObject(wrappedValue: MeasurementEngine(camera: cam, motion: mot))
    }

    var body: some Scene {
        WindowGroup {
            RangefinderView(motion: motion)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(camera)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

enum Fmt {
    static func yd(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
    static func yd1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func signed(_ v: Double?) -> String { v.map { String(format: "%+.1f", $0) } ?? "—" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", 100 * $0) } ?? "—" }
}
