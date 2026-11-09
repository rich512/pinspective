import Foundation

/// A field calibration of the lens focal length: the ratio k between the true focal length and
/// the focal length the camera reports, measured on an object of known height at a known
/// (tape-measured) distance.
struct LensCalibration: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var cameraKey: String
    var k: Double
    var sigmaK: Double            // 1-sigma, absolute (k is ~1, so this is ~relative)
    var objectHeightIn: Double
    var objectSigmaIn: Double
    var distanceM: Double
    var distanceSigmaM: Double
    var framesUsed: Int
    var spanPx: Double
    var fxReported: Double
    var intrinsicsSource: String
}

final class AppSettings: ObservableObject {
    private let ud = UserDefaults.standard

    // Flagstick model
    @Published var flagHeightIn: Double { didSet { ud.set(flagHeightIn, forKey: "flagHeightIn") } }
    @Published var flagSigmaIn: Double { didSet { ud.set(flagSigmaIn, forKey: "flagSigmaIn") } }
    @Published var baseSigmaIn: Double { didSet { ud.set(baseSigmaIn, forKey: "baseSigmaIn") } }

    // Measurement rules
    @Published var burstFrames: Int { didSet { ud.set(burstFrames, forKey: "burstFrames") } }
    @Published var maxRel95Pct: Double { didSet { ud.set(maxRel95Pct, forKey: "maxRel95Pct") } }
    @Published var minValidFraction: Double { didSet { ud.set(minValidFraction, forKey: "minValidFraction") } }
    @Published var uncalibratedFocalSigmaPct: Double { didSet { ud.set(uncalibratedFocalSigmaPct, forKey: "uncalFocalPct") } }

    // Test-session conditions, copied onto every measurement
    @Published var station: String { didSet { ud.set(station, forKey: "station") } }
    @Published var lighting: String { didSet { ud.set(lighting, forKey: "lighting") } }
    @Published var background: String { didSet { ud.set(background, forKey: "background") } }
    @Published var flagType: String { didSet { ud.set(flagType, forKey: "flagType") } }

    @Published var calibrations: [LensCalibration] { didSet { saveCalibrations() } }

    static let lightingOptions = ["Sunny", "Overcast", "Backlit", "Low sun / dusk", "Rain / haze"]
    static let backgroundOptions = ["Trees", "Sky", "Mixed", "Hillside / grass", "Buildings"]

    init() {
        let ud = UserDefaults.standard   // local, so the helpers don't capture self before init completes
        func d(_ k: String, _ def: Double) -> Double { ud.object(forKey: k) == nil ? def : ud.double(forKey: k) }
        func i(_ k: String, _ def: Int) -> Int { ud.object(forKey: k) == nil ? def : ud.integer(forKey: k) }
        func s(_ k: String, _ def: String) -> String { ud.string(forKey: k) ?? def }
        flagHeightIn = d("flagHeightIn", 84)
        flagSigmaIn = d("flagSigmaIn", 6)
        baseSigmaIn = d("baseSigmaIn", 1.0)
        burstFrames = i("burstFrames", 30)
        maxRel95Pct = d("maxRel95Pct", 10)
        minValidFraction = d("minValidFraction", 0.5)
        uncalibratedFocalSigmaPct = d("uncalFocalPct", 2.0)
        station = s("station", "")
        lighting = s("lighting", "Sunny")
        background = s("background", "Trees")
        flagType = s("flagType", "")
        if let data = ud.data(forKey: "calibrations"),
           let c = try? JSONDecoder().decode([LensCalibration].self, from: data) {
            calibrations = c
        } else {
            calibrations = []
        }
    }

    private func saveCalibrations() {
        if let data = try? JSONEncoder().encode(calibrations) { ud.set(data, forKey: "calibrations") }
    }

    /// Combined calibration for one camera/format: inverse-variance mean of k. If the individual
    /// calibrations disagree more than their stated errors allow, the error is inflated by
    /// sqrt(chi^2 / dof). A 0.3% floor covers effects a single session can't see (focus
    /// position, temperature).
    func focalScale(for cameraKey: String) -> (k: Double, sigma: Double, count: Int) {
        let cs = calibrations.filter { $0.cameraKey == cameraKey && $0.sigmaK > 0 }
        guard !cs.isEmpty else { return (1, uncalibratedFocalSigmaPct / 100, 0) }
        let w = cs.map { 1 / ($0.sigmaK * $0.sigmaK) }
        let sw = w.reduce(0, +)
        let k = zip(cs, w).reduce(0) { $0 + $1.0.k * $1.1 } / sw
        var sig = 1 / sqrt(sw)
        if cs.count >= 2 {
            let chi2 = zip(cs, w).reduce(0) { $0 + ($1.0.k - k) * ($1.0.k - k) * $1.1 }
            let r = chi2 / Double(cs.count - 1)
            if r > 1 { sig *= sqrt(r) }
        }
        return (k, max(sig, 0.003), cs.count)
    }
}
