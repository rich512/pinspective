import Foundation

/// Accuracy metrics for a group of logged attempts. Only attempts with a laser distance
/// entered count; success rate uses every such attempt, error metrics use the successful ones.
struct AccuracyMetrics {
    var label: String
    var attempts = 0
    var successes = 0
    var n = 0
    var mae: Double?
    var medianError: Double?       // signed: + means the app reads long
    var medianAbsError: Double?
    var p90AbsError: Double?
    var meanError: Double?         // bias
    var rmse: Double?
    var coverage95: Double?        // fraction of results whose 95% interval contained the laser value
    var repeatabilitySD: Double?   // pooled SD of repeat readings at the same station + distance
    var repeatGroups = 0
    var medianTimeS: Double?

    var successRate: Double? { attempts > 0 ? Double(successes) / Double(attempts) : nil }

    init(label: String, records: [MeasurementRecord], errorOf: (MeasurementRecord) -> Double? = { $0.errorYd }) {
        self.label = label
        let withTruth = records.filter { $0.actualYd != nil }
        attempts = withTruth.count
        let ok = withTruth.filter { $0.status == "ok" }
        successes = ok.count
        let errs = withTruth.compactMap(errorOf)
        n = errs.count
        if !errs.isEmpty {
            let abse = errs.map(abs)
            mae = Stats.mean(abse)
            medianError = Stats.median(errs)
            medianAbsError = Stats.median(abse)
            p90AbsError = Stats.percentile(abse, 90)
            meanError = Stats.mean(errs)
            rmse = sqrt(Stats.mean(errs.map { $0 * $0 }))
        }
        let cov = ok.compactMap { $0.within95 }
        if !cov.isEmpty { coverage95 = Double(cov.filter { $0 }.count) / Double(cov.count) }

        // repeatability: same station label and same laser distance (to the nearest yard)
        var groups: [String: [Double]] = [:]
        for r in ok {
            guard let e = r.estimateYd, let a = r.actualYd else { continue }
            groups["\(r.station)|\(Int(a.rounded()))", default: []].append(e)
        }
        var num = 0.0, den = 0.0
        for (_, v) in groups where v.count >= 2 {
            let s = Stats.sd(v)
            num += Double(v.count - 1) * s * s
            den += Double(v.count - 1)
            repeatGroups += 1
        }
        if den > 0 { repeatabilitySD = sqrt(num / den) }
        let times = withTruth.map { $0.timeToResultS }.filter { $0 > 0 }
        if !times.isEmpty { medianTimeS = Stats.median(times) }
    }
}

enum AccuracyReport {
    static let bands: [Double] = [50, 100, 150, 200, 250]

    static func band(of yd: Double) -> Double? {
        bands.first { abs($0 - yd) <= 25 }
    }

    static func byDistance(_ rs: [MeasurementRecord]) -> [AccuracyMetrics] {
        bands.map { b in AccuracyMetrics(label: "\(Int(b)) yd", records: rs.filter { $0.actualYd.flatMap(band) == b }) }
    }

    static func byField(_ rs: [MeasurementRecord], _ key: (MeasurementRecord) -> String) -> [AccuracyMetrics] {
        let keys = Set(rs.filter { $0.actualYd != nil }.map(key)).sorted()
        return keys.map { k in AccuracyMetrics(label: k.isEmpty ? "(blank)" : k, records: rs.filter { key($0) == k }) }
    }

    /// Head-to-head on the same attempts: what each method would have scored.
    static func byMethod(_ rs: [MeasurementRecord]) -> [AccuracyMetrics] {
        func err(_ v: Double?, _ ok: Bool, _ r: MeasurementRecord) -> Double? {
            guard ok, let v, let a = r.actualYd, r.status != "rejected-lines" else { return nil }
            return v - a
        }
        return [
            AccuracyMetrics(label: "A single frame", records: rs) { err($0.aDistanceYd, $0.aAvailable, $0) },
            AccuracyMetrics(label: "C multi-frame", records: rs) { err($0.cDistanceYd, $0.cAvailable, $0) },
            AccuracyMetrics(label: "A manual lines", records: rs) { err($0.manualDistanceYd, $0.manualAvailable, $0) },
        ]
    }
}
