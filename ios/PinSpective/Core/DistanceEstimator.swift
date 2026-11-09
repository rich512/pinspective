import Foundation

let metersPerYard = 0.9144
let metersPerInch = 0.0254

/// One analysed frame from a burst.
struct FrameSample {
    var geo: FrameGeometry
    var det: StickDetection?
    var time: Double
    var intrinsicsSource: String
    var iso: Float
    var exposureS: Double
    var lensPosition: Float
    var processingMs: Double
}

/// Inputs to the uncertainty model. All sigmas are 1-sigma.
struct EstimateConfig {
    var heightM: Double            // visible flagstick height: green surface to top of stick
    var sigmaHeightM: Double       // how well that height is known
    var sigmaBaseM: Double         // where the base really is (grass, cup lip, partial occlusion)
    var k: Double                  // focal-length calibration factor
    var sigmaKRel: Double
    var maxRel95: Double           // refuse to report if the 95% half-width exceeds this fraction
    var minValidFraction: Double
    static let minSpanPx = 25.0

    var relHeight: Double { sigmaHeightM / heightM }
    var relBase: Double { sigmaBaseM / heightM }
}

/// A distance estimate from one method, with the uncertainty broken into its parts.
struct MethodEstimate: Codable {
    var method: String
    var available: Bool
    var reason: String?
    /// The computed value, kept for analysis even when `available` is false. The UI never shows
    /// it when unavailable.
    var distanceM: Double?
    var relSigma: Double?
    var relRandom: Double?
    var spanPx: Double?
    var nUsed: Int
    var nTotal: Int
    var warnings: [String] = []

    var distanceYd: Double? { distanceM.map { $0 / metersPerYard } }
    var sigmaYd: Double? {
        guard let d = distanceYd, let r = relSigma else { return nil }
        return d * r
    }
    /// 95% interval, ±1.96 sigma.
    var halfWidth95Yd: Double? { sigmaYd.map { 1.96 * $0 } }
}

enum DistanceEstimator {

    /// Per-frame horizontal distance from the detected top and base.
    static func frameDistance(_ s: FrameSample, cfg: EstimateConfig) -> (X: Double, span: Double)? {
        guard let d = s.det, d.ok else { return nil }
        guard let X = s.geo.horizontalDistance(topU: d.x, topV: d.yTop, baseU: d.x, baseV: d.yBot,
                                                heightM: cfg.heightM, k: cfg.k),
              X > 1, X < 2000 else { return nil }
        return (X, d.span)
    }

    private static func finish(_ e: inout MethodEstimate, X: Double, span: Double, relRand: Double, cfg: EstimateConfig) {
        let rel = sqrt(relRand * relRand + cfg.relHeight * cfg.relHeight + cfg.relBase * cfg.relBase + cfg.sigmaKRel * cfg.sigmaKRel)
        e.distanceM = X
        e.relSigma = rel
        e.relRandom = relRand
        e.spanPx = span
        if span < EstimateConfig.minSpanPx {
            e.available = false
            e.reason = String(format: "Stick only %.0f px tall in the image (need ≥ %.0f)", span, EstimateConfig.minSpanPx)
        } else if 1.96 * rel > cfg.maxRel95 {
            e.available = false
            e.reason = String(format: "Uncertainty ±%.1f%% exceeds the ±%.0f%% limit", 196 * rel, 100 * cfg.maxRel95)
                + dominantTermNote(relRand: relRand, cfg: cfg)
        } else {
            e.available = true
        }
    }

    private static func dominantTermNote(relRand: Double, cfg: EstimateConfig) -> String {
        let terms = [("flag height", cfg.relHeight), ("base visibility", cfg.relBase),
                     ("lens calibration", cfg.sigmaKRel), ("image noise", relRand)]
        let top = terms.max { $0.1 < $1.1 }!
        return " (largest term: \(top.0))"
    }

    /// Method A: a single frame (the valid frame nearest the middle of the burst).
    /// Pixel term: 0.5 px per edge for the automatic detector, independent edges.
    static func singleFrame(_ frames: [FrameSample], cfg: EstimateConfig) -> MethodEstimate {
        var e = MethodEstimate(method: "A-single-frame", available: false, nUsed: 0, nTotal: frames.count)
        let mid = frames.count / 2
        let order = frames.indices.sorted { abs($0 - mid) < abs($1 - mid) }
        for i in order {
            if let r = frameDistance(frames[i], cfg: cfg) {
                e.nUsed = 1
                finish(&e, X: r.X, span: r.span, relRand: sqrt(2) * 0.5 / r.span, cfg: cfg)
                e.warnings.append("Single-frame pixel error is modelled, not measured: heat shimmer and hand shake are not included.")
                return e
            }
        }
        e.reason = "Flagstick not found in any frame"
        return e
    }

    /// Method A with lines placed by the user on the frozen frame (0.75 px per edge).
    static func manual(_ s: FrameSample, topV: Double, baseV: Double, u: Double, cfg: EstimateConfig) -> MethodEstimate {
        var e = MethodEstimate(method: "A-manual", available: false, nUsed: 1, nTotal: 1)
        guard let X = s.geo.horizontalDistance(topU: u, topV: topV, baseU: u, baseV: baseV, heightM: cfg.heightM, k: cfg.k),
              X > 1, X < 2000 else {
            e.reason = "Top line must be above the base line"
            return e
        }
        let span = baseV - topV
        finish(&e, X: X, span: span, relRand: sqrt(2) * 0.75 / span, cfg: cfg)
        return e
    }

    /// Method C: robust combination of every frame in the burst.
    /// - Outliers beyond 3.5 robust sigma from the median are dropped.
    /// - Random error = robust scatter / sqrt(n_eff), n_eff = n/3. Successive frames are not
    ///   independent (shimmer and hand shake are correlated over tens of ms), so this is a
    ///   deliberately conservative assumption; the repeatability test checks it.
    /// - Floor of 0.25 px per edge: averaging cannot remove a consistent edge-location bias.
    static func multiFrame(_ frames: [FrameSample], cfg: EstimateConfig) -> MethodEstimate {
        var e = MethodEstimate(method: "C-multi-frame", available: false, nUsed: 0, nTotal: frames.count)
        let rs = frames.compactMap { frameDistance($0, cfg: cfg) }
        let needed = max(5, Int(ceil(cfg.minValidFraction * Double(frames.count))))
        if rs.isEmpty { e.reason = "Flagstick not found in any frame"; return e }
        let xs = rs.map { $0.X }
        let med0 = Stats.median(xs), rsig0 = Stats.robustSigma(xs)
        let inl = rsig0 > 0 ? rs.filter { abs($0.X - med0) <= 3.5 * rsig0 } : rs
        let X = Stats.median(inl.map { $0.X })
        let span = Stats.median(inl.map { $0.span })
        e.nUsed = inl.count
        let nEff = max(1.0, Double(inl.count) / 3)
        let scatter = Stats.robustSigma(inl.map { $0.X }) / X / sqrt(nEff)
        let floorPx = sqrt(2) * 0.25 / span
        finish(&e, X: X, span: span, relRand: max(scatter, floorPx), cfg: cfg)
        if rs.count < needed {
            e.available = false
            e.reason = "Flagstick found in only \(rs.count) of \(frames.count) frames (need \(needed))"
        }
        if inl.count < rs.count { e.warnings.append("\(rs.count - inl.count) outlier frame(s) dropped") }
        let cs = frames.compactMap { $0.det?.ok == true ? $0.det!.contrast : nil }
        if !cs.isEmpty && Stats.median(cs) < 1.6 { e.warnings.append("Low contrast: check the lines") }
        let flagFrac = Double(frames.filter { $0.det?.usedFlagEdge == true }.count) / Double(max(1, frames.count))
        if flagFrac > 0.5 { e.warnings.append("Top located through the flag cloth: check the red line is the top of the stick") }
        return e
    }

    /// Lens calibration: per frame, find k so that the computed distance equals the known
    /// distance (bisection; distance increases monotonically with k), then take the median.
    static func calibrate(_ frames: [FrameSample], objectHeightM: Double, objectSigmaM: Double,
                          distanceM: Double, distanceSigmaM: Double) -> (k: Double, sigma: Double, n: Int, span: Double)? {
        var ks: [Double] = [], spans: [Double] = []
        for s in frames {
            guard let d = s.det, d.ok else { continue }
            var lo = 0.5, hi = 2.0
            func X(_ k: Double) -> Double? {
                s.geo.horizontalDistance(topU: d.x, topV: d.yTop, baseU: d.x, baseV: d.yBot, heightM: objectHeightM, k: k)
            }
            guard let xl = X(lo), let xh = X(hi), xl < distanceM, xh > distanceM else { continue }
            for _ in 0..<50 {
                let m = (lo + hi) / 2
                guard let xm = X(m) else { break }
                if xm < distanceM { lo = m } else { hi = m }
            }
            ks.append((lo + hi) / 2)
            spans.append(d.span)
        }
        guard ks.count >= 5 else { return nil }
        let k = Stats.median(ks)
        let nEff = max(1.0, Double(ks.count) / 3)
        let rand = Stats.robustSigma(ks) / k / sqrt(nEff)
        let span = Stats.median(spans)
        let px = sqrt(2) * 0.25 / span
        let rel = sqrt(rand * rand + px * px + pow(objectSigmaM / objectHeightM, 2) + pow(distanceSigmaM / distanceM, 2))
        return (k, rel * k, ks.count, span)
    }
}
