import Foundation

/// One measurement attempt, as logged and exported. Every attempt should be saved (including
/// "unavailable" and lines-wrong results), otherwise the success rate is meaningless.
struct MeasurementRecord: Codable, Identifiable {
    var id = UUID()
    var timestamp = Date()
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    // Outcome
    var status: String              // ok | unavailable | rejected-lines
    var reportedMethod: String      // the method whose number was shown
    var estimateYd: Double?         // nil unless status == ok
    var sigmaYd: Double?
    var halfWidth95Yd: Double?
    var unavailableReason: String?
    var warnings: String = ""
    var linesCheck = "not-checked"   // not-checked | correct | wrong | manual

    // Ground truth (laser), entered by the tester
    var actualYd: Double?
    var station: String = ""
    var notes: String = ""

    // Per-method results (raw values kept even if unavailable, for analysis)
    var aDistanceYd: Double?, aSigmaYd: Double?, aAvailable: Bool = false
    var cDistanceYd: Double?, cSigmaYd: Double?, cAvailable: Bool = false
    var manualDistanceYd: Double?, manualSigmaYd: Double?, manualAvailable: Bool = false

    // Uncertainty components (relative, 1 sigma)
    var relRandom: Double?, relHeight: Double = 0, relBase: Double = 0, relFocal: Double = 0

    // Image / detector diagnostics
    var framesTotal = 0, framesValid = 0, framesUsed = 0
    var spanPxMedian: Double?, spanPxSD: Double?, contrastMedian: Double?
    var flagEdgeFraction: Double = 0

    // Camera
    var cameraDevice = "", bufferW = 0, bufferH = 0
    var fx: Double = 0, fy: Double = 0, cx: Double = 0, cy: Double = 0
    var intrinsicsSource = ""
    var focalK: Double = 1, focalKSigma: Double = 0, calibrationCount = 0
    var lensPosition: Double = 0, iso: Double = 0, exposureMs: Double = 0
    var focusLocked = false

    // Orientation
    var pitchDeg: Double = 0, rollDeg: Double = 0, pitchJitterDeg: Double = 0

    // Flagstick model
    var flagHeightIn: Double = 0, flagSigmaIn: Double = 0, baseSigmaIn: Double = 0

    // Conditions
    var lighting = "", background = "", flagType = ""

    // Timing
    var timeToResultS: Double = 0, burstDurationS: Double = 0, processingMsMedian: Double = 0

    // Derived
    var errorYd: Double? {
        guard status == "ok", let e = estimateYd, let a = actualYd else { return nil }
        return e - a
    }
    var within95: Bool? {
        guard let err = errorYd, let h = halfWidth95Yd else { return nil }
        return abs(err) <= h
    }
}

final class MeasurementStore: ObservableObject {
    @Published var records: [MeasurementRecord] = [] { didSet { save() } }

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("measurements.json")
    }

    init() {
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let r = try? dec.decode([MeasurementRecord].self, from: data) { records = r }
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ r: MeasurementRecord) { records.insert(r, at: 0) }

    func update(_ r: MeasurementRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r }
    }

    // MARK: CSV

    func csv() -> String {
        let f = ISO8601DateFormatter()
        func n(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        func q(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return s
        }
        let header = ["id", "timestamp", "app_version", "station", "status", "reported_method",
                      "estimate_yd", "sigma_yd", "ci95_halfwidth_yd", "actual_yd", "error_yd", "abs_error_yd", "within_95",
                      "unavailable_reason", "warnings", "lines_check",
                      "A_single_yd", "A_sigma_yd", "A_available", "C_multi_yd", "C_sigma_yd", "C_available",
                      "manual_yd", "manual_sigma_yd", "manual_available",
                      "rel_random", "rel_height", "rel_base", "rel_focal",
                      "frames_total", "frames_valid", "frames_used", "span_px_median", "span_px_sd", "contrast_median", "flag_edge_fraction",
                      "camera", "buffer_w", "buffer_h", "fx", "fy", "cx", "cy", "intrinsics_source",
                      "focal_k", "focal_k_sigma", "calibration_count", "lens_position", "iso", "exposure_ms", "focus_locked",
                      "pitch_deg", "roll_deg", "pitch_jitter_deg",
                      "flag_height_in", "flag_sigma_in", "base_sigma_in",
                      "lighting", "background", "flag_type",
                      "time_to_result_s", "burst_duration_s", "processing_ms_median", "notes"]
        var lines = [header.joined(separator: ",")]
        for r in records.reversed() {
            let row: [String] = [
                r.id.uuidString, f.string(from: r.timestamp), r.appVersion, q(r.station), r.status, r.reportedMethod,
                n(r.estimateYd), n(r.sigmaYd), n(r.halfWidth95Yd), n(r.actualYd, 1), n(r.errorYd), n(r.errorYd.map(abs)),
                r.within95.map { $0 ? "1" : "0" } ?? "",
                q(r.unavailableReason ?? ""), q(r.warnings), r.linesCheck,
                n(r.aDistanceYd), n(r.aSigmaYd), r.aAvailable ? "1" : "0",
                n(r.cDistanceYd), n(r.cSigmaYd), r.cAvailable ? "1" : "0",
                n(r.manualDistanceYd), n(r.manualSigmaYd), r.manualAvailable ? "1" : "0",
                n(r.relRandom, 5), n(r.relHeight, 5), n(r.relBase, 5), n(r.relFocal, 5),
                "\(r.framesTotal)", "\(r.framesValid)", "\(r.framesUsed)", n(r.spanPxMedian), n(r.spanPxSD), n(r.contrastMedian),
                n(r.flagEdgeFraction),
                q(r.cameraDevice), "\(r.bufferW)", "\(r.bufferH)", n(r.fx), n(r.fy), n(r.cx), n(r.cy), r.intrinsicsSource,
                n(r.focalK, 5), n(r.focalKSigma, 5), "\(r.calibrationCount)", n(r.lensPosition, 4), n(r.iso, 0), n(r.exposureMs, 3),
                r.focusLocked ? "1" : "0",
                n(r.pitchDeg, 3), n(r.rollDeg, 3), n(r.pitchJitterDeg, 3),
                n(r.flagHeightIn), n(r.flagSigmaIn), n(r.baseSigmaIn),
                q(r.lighting), q(r.background), q(r.flagType),
                n(r.timeToResultS), n(r.burstDurationS), n(r.processingMsMedian, 1), q(r.notes)
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the CSV to a temporary file for the share sheet.
    func exportCSV() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinSpective-measurements-\(df.string(from: Date())).csv")
        do { try csv().write(to: u, atomically: true, encoding: .utf8); return u } catch { return nil }
    }
}
