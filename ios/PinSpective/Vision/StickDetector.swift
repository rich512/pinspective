import Foundation

/// Result of looking for a flagstick inside a gravity-aligned region of interest (ROI).
/// Coordinates are ROI "edge" coordinates: sample index i covers [i, i+1), so a sample's
/// centre is at i + 0.5. `yTop` / `yBot` are sub-pixel edge positions along the vertical
/// (gravity) axis; `x` is the stick's column centre.
struct StickDetection {
    var x: Double
    var yTop: Double
    var yBot: Double
    /// Ridge strength of the stick relative to the background noise threshold.
    var contrast: Double
    /// True when the top was extended through the flag cloth using a step-edge test.
    var usedFlagEdge: Bool
    var ok: Bool
    var span: Double { yBot - yTop }
}

/// Classical computer-vision flagstick finder.
///
/// This is a direct port of the detector in the PinSpective web prototype (index.html,
/// `analyzeROI`), which was already working in the field. Steps:
///  1. Ridge filter at three widths on luma and on chroma (a thin bright-or-dark line).
///  2. Robust noise threshold from the median/MAD of the ridge response.
///  3. For every column, the best contiguous vertical run above threshold (Kadane).
///  4. Pick the run that best fits the aim point; prefer the longest overlapping run
///     nearby (the stick under the flag rather than the flag cloth itself).
///  5. Find the top by walking up from the base along a polarity-consistent profile, then
///     extend through flag cloth only if it looks like cloth (continuous single edge), or
///     through a limp, wrapped flag (uniform patch wider than the stick).
///  6. Sub-pixel top/base by interpolating where the profile crosses half level.
///
/// Steps 4–5 were changed from the web version after synthetic tests showed the original
/// running the top up into tree texture by hundreds of pixels (docs/FEASIBILITY.md).
enum StickDetector {

    static func detect(Y: [Float], C: [Float], w rw: Int, h rh: Int,
                       seedX sx: Double, seedY sy: Double,
                       aimSigmaX: Double = 40, walkFraction: Float = 0.4) -> StickDetection? {
        let M = 7
        guard rw > 2 * M + 6, rh > 24, Y.count == rw * rh, C.count == rw * rh else { return nil }
        let N = rw * rh
        var R = [Float](repeating: 0, count: N)

        // 1. ridge response
        Y.withUnsafeBufferPointer { Yp in
            C.withUnsafeBufferPointer { Cp in
                R.withUnsafeMutableBufferPointer { Rp in
                    for y in 0..<rh {
                        let o = y * rw
                        for x in M..<(rw - M) {
                            let i = o + x
                            var best: Float = 0
                            // widths 2, 4, 7 (unrolled)
                            for dd in [2, 4, 7] {
                                var a = Yp[i] - Yp[i - dd], b = Yp[i] - Yp[i + dd]
                                if a * b > 0 { let v = min(abs(a), abs(b)); if v > best { best = v } }
                                a = Cp[i] - Cp[i - dd]; b = Cp[i] - Cp[i + dd]
                                if a * b > 0 { let v = min(abs(a), abs(b)) * 0.8; if v > best { best = v } }
                            }
                            Rp[i] = best
                        }
                    }
                }
            }
        }

        // 2. noise level from a sample of the whole ROI
        var smp: [Float] = []
        smp.reserveCapacity(N / 7 + 1)
        var si = 0
        while si < N { smp.append(R[si]); si += 7 }
        let nm = Stats.median(smp)
        var mad = Stats.median(smp.map { abs($0 - nm) })
        if mad == 0 { mad = 1 }
        let tau = nm + 3 * mad + 1

        // 3. per-column best contiguous run
        func kadane(_ p: [Float], _ t: Float, _ lo: Int, _ hi: Int) -> (a: Int, b: Int, s: Float) {
            var cur: Float = 0, st = lo, bs: Float = 0, ba = 0, bb = -1
            if hi > lo {
                for y in lo..<hi {
                    let v = p[y] - t
                    if cur <= 0 { cur = v; st = y } else { cur += v }
                    if cur > bs { bs = cur; ba = st; bb = y }
                }
            }
            return (ba, bb, bs)
        }
        func colProf(_ x: Int) -> [Float] {
            var out = [Float](repeating: 0, count: rh)
            for y in 0..<rh {
                let o = y * rw + x
                out[y] = max(R[o - 1], max(R[o], R[o + 1]))
            }
            return out
        }

        var runs = [(a: Int, b: Int, s: Float)?](repeating: nil, count: rw)
        var seed: (x: Int, a: Int, b: Int, s: Float, wsc: Double)? = nil
        let sigX = max(aimSigmaX, Double(rw) * 0.1)
        let sigY = max(30.0, Double(rh) * 0.05)
        for x in (M + 1)..<(rw - M - 1) {
            let k = kadane(colProf(x), tau, 0, rh)
            runs[x] = k
            if k.b < k.a { continue }
            // The golfer aims at the flag, near the top of the stick: penalise runs whose top is far from the aim point.
            let len = Double(k.b - k.a), a = Double(k.a)
            let dy: Double = sy < a ? a - sy : (sy - a > 0.65 * len ? sy - a - 0.65 * len : 0)
            let wsc = Double(k.s) * exp(-0.5 * pow((Double(x) - sx) / sigX, 2)) * exp(-0.5 * pow(dy / sigY, 2))
            if seed == nil || wsc > seed!.wsc { seed = (x, k.a, k.b, k.s, wsc) }
        }
        guard let sd = seed else { return nil }

        // 4. the seed may be the flag cloth: the stick is the longest overlapping run nearby
        let K = max(8, Int((0.4 * Double(sd.b - sd.a + 1)).rounded()))
        var xc = sd.x, ca = sd.a, cb = sd.b
        let lo4 = max(M + 1, sd.x - K), hi4 = min(rw - M - 2, sd.x + K)
        if hi4 >= lo4 {
            for x in lo4...hi4 {
                guard let k = runs[x], k.b >= k.a, k.s >= 0.15 * sd.s else { continue }
                if k.b < sd.a - 3 || k.a > sd.b + 3 { continue }
                // a stick hanging below a flag starts near the flag and ends well below it; a trunk starts far above
                let sl = Double(sd.b - sd.a)
                if Double(k.a) < Double(sd.a) - 0.3 * sl - 3 || Double(k.b) < Double(sd.b) + 0.5 * sl { continue }
                if k.b - k.a > cb - ca { xc = x; ca = k.a; cb = k.b }
            }
        }
        let pc = colProf(xc)
        // Stick strength from the bottom quarter of the run (just above the base, which is always
        // stick). A median over the whole run collapses when tree texture dominates the run.
        let q = max(10, (cb - ca) / 4)
        let core = Stats.median(Array(pc[max(ca, cb - q)...cb]))
        let tau2 = max(tau, 0.3 * core)
        var a = ca, b = cb
        do {
            let k = kadane(pc, tau2, max(0, ca - 4), min(rh, cb + 5))
            if k.b >= k.a && Double(k.b - k.a) > 0.6 * Double(cb - ca) { a = k.a; b = k.b }
        }

        // Walk up from the base along a signed (polarity-consistent) thin-line profile. A stick
        // against one background keeps its polarity (e.g. bright on dark); texture flips sign,
        // so a 9-row median stops within a few rows of the real top.
        var sp = [Float](repeating: 0, count: rh)
        for yy in 0..<rh {
            let o = yy * rw
            var m = -Float.greatestFiniteMagnitude
            for x in (xc - 1)...(xc + 1) {
                let v = Y[o + x] - (Y[o + x - 2] + Y[o + x + 2]) / 2
                if v > m { m = v }
            }
            sp[yy] = m
        }
        let q4 = max(10, (b - a) / 4)
        if Stats.median(Array(sp[max(a, b - q4)...b])) < 0 {
            // dark stick: recompute with the opposite polarity
            for yy in 0..<rh {
                let o = yy * rw
                var m = -Float.greatestFiniteMagnitude
                for x in (xc - 1)...(xc + 1) {
                    let v = -(Y[o + x] - (Y[o + x - 2] + Y[o + x + 2]) / 2)
                    if v > m { m = v }
                }
                sp[yy] = m
            }
        }
        let cs = Stats.median(Array(sp[max(a, b - q4)...b]))
        let walkThr: Float? = cs > 3 ? walkFraction * cs : nil
        if let thr = walkThr {
            var y = b - 4
            while y - 1 >= a && Stats.median(Array(sp[max(0, y - 5)..<min(rh, y + 4)])) >= thr { y -= 1 }
            if b - y >= 6 { a = max(a, y) }
        }

        // Step-edge strength beside the stick (for the flag cloth)
        func Eat(_ y: Int, _ xm: Int) -> Float {
            var m: Float = 0
            let o = y * rw
            let x0 = max(4, xm - 3), x1 = min(rw - 5, xm + 3)
            if x1 < x0 { return 0 }
            for x in x0...x1 {
                let l = (Y[o + x - 1] + Y[o + x - 2] + Y[o + x - 3]) / 3
                let r = (Y[o + x + 1] + Y[o + x + 2] + Y[o + x + 3]) / 3
                let lc = (C[o + x - 1] + C[o + x - 2] + C[o + x - 3]) / 3
                let rc = (C[o + x + 1] + C[o + x + 2] + C[o + x + 3]) / 3
                let v = max(abs(l - r), 0.8 * abs(lc - rc))
                if v > m { m = v }
            }
            return m
        }
        func E(_ y: Int) -> Float { Eat(y, xc) }
        // noise level of the same operator at random places
        var es: [Float] = []
        es.reserveCapacity(400)
        for i in 0..<400 {
            let y = (i * 37) % rh
            let x = 13 + ((i * 101) % max(1, rw - 26))
            es.append(Eat(y, x))
        }
        let em = Stats.median(es)
        var emad = Stats.median(es.map { abs($0 - em) })
        if emad == 0 { emad = 1 }
        let tauE = em + 4 * emad + 3

        // Extend the top up through the flag cloth
        var top = a, usedE = false, gap = 0
        let lim = max(0, Int(floor(Double(a) - 0.45 * Double(b - a + 1))))
        var y = a - 1
        while y >= lim {
            let byR = walkThr.map { sp[y] >= $0 } ?? (pc[y] > tau2)
            let byE = !byR && E(y) > tauE
            if byR || byE { top = y; gap = 0; if byE { usedE = true } }
            else { gap += 1; if gap > 2 { break } }
            y -= 1
        }
        // Cloth check: one edge at a fixed column with consistent polarity, and a flag-sized extension.
        if top < a && usedE {
            let n = a - top
            var okc = false
            if Double(n) >= 0.06 * Double(b - a) && Double(n) <= 0.3 * Double(b - a) {
                var best = 0
                for col in max(4, xc - 3)...max(max(4, xc - 3), min(rw - 5, xc + 3)) {
                    for useC in [false, true] {
                        var pos = 0, neg = 0
                        for yy in top..<a {
                            let o = yy * rw + col
                            let v: Float = useC
                                ? (C[o - 1] + C[o - 2] + C[o - 3]) / 3 - (C[o + 1] + C[o + 2] + C[o + 3]) / 3
                                : (Y[o - 1] + Y[o - 2] + Y[o - 3]) / 3 - (Y[o + 1] + Y[o + 2] + Y[o + 3]) / 3
                            if v > tauE { pos += 1 } else if v < -tauE { neg += 1 }
                        }
                        best = max(best, max(pos, neg))
                    }
                }
                okc = Double(best) >= 0.85 * Double(n)
            }
            if !okc { top = a; usedE = false }
        }

        // Limp flag wrapped around the stick: a uniform patch wider than the stick directly above
        // the visible stick top, ending in a clear change, flag-sized.
        var blobTop: Int? = nil
        var blobRefY: Float = 0
        if top == a && a > 8 {
            func band(_ A: [Float], _ y: Int, _ c0: Int, _ c1: Int) -> Float {
                var s: Float = 0
                for x in c0...c1 { s += A[y * rw + x] }
                return s / Float(c1 - c0 + 1)
            }
            var refY: [Float] = [], refC: [Float] = []
            for yy in (a - 6)..<(a - 1) { refY.append(band(Y, yy, xc - 1, xc + 1)); refC.append(band(C, yy, xc - 1, xc + 1)) }
            let rY = Stats.median(refY), rC = Stats.median(refC), tol: Float = 12
            func like(_ yy: Int, _ c0: Int, _ c1: Int) -> Bool {
                abs(band(Y, yy, c0, c1) - rY) < tol && abs(band(C, yy, c0, c1) - rC) < tol
            }
            let lim2 = max(0, Int(Double(a) - 0.3 * Double(b - a)))
            let wl = max(0, xc - 3), wr = min(rw - 1, xc + 3)
            var yy = a - 1, bt = a, miss = 0
            while yy >= lim2 {
                if like(yy, xc - 1, xc + 1) && like(yy, wl, wl + 1) && like(yy, wr - 1, wr) { bt = yy; miss = 0 }
                else { miss += 1; if miss > 1 { break } }
                yy -= 1
            }
            let n = a - bt
            if yy >= lim2 - 1 && Double(n) >= 0.06 * Double(b - a) && Double(n) <= 0.3 * Double(b - a) && bt >= 5 {
                var diff = 0
                for z in (bt - 4)..<bt where !like(z, xc - 1, xc + 1) { diff += 1 }
                if diff >= 3 { blobTop = bt; blobRefY = rY }
            }
        }
        if let bt = blobTop { top = bt; usedE = true }

        if sd.x != xc && sd.a < top && sd.b >= top - 3 && Double(sd.b) <= Double(a) + 0.35 * Double(b - a)
            && Double(top - sd.a) < 0.45 * Double(b - a) { top = sd.a }

        // 6. sub-pixel edges at the half level
        let L = (core + nm) / 2
        var yTop = Double(top), yBot = Double(b + 1)
        if let bt = blobTop {
            func bvY(_ yy: Int) -> Float { (Y[yy * rw + xc - 1] + Y[yy * rw + xc] + Y[yy * rw + xc + 1]) / 3 }
            let v0 = bvY(bt), v1 = bvY(bt - 1), mid = (blobRefY + v1) / 2
            yTop = abs(v0 - v1) > 1e-3 ? Double(bt) + 0.5 - clampH(Double((v0 - mid) / (v0 - v1))) : Double(bt)
        } else if top == a && a > 0 && pc[a] > pc[a - 1] {
            yTop = Double(a) + 0.5 - clampH(Double((pc[a] - L) / (pc[a] - pc[a - 1])))
        } else if top != a && top > 0 {
            var ev: [Float] = []
            for yy in top..<a { ev.append(E(yy)) }
            let eL = (Stats.median(ev) + em) / 2
            var yy = top
            while yy < a - 1 && E(yy) < eL { yy += 1 }
            let e0 = E(yy), e1 = E(yy - 1)
            yTop = e0 > e1 ? Double(yy) + 0.5 - clampH(Double((e0 - eL) / (e0 - e1))) : Double(yy)
        }
        if b < rh - 1 && pc[b] > pc[b + 1] {
            yBot = Double(b) + 0.5 + clampH(Double((pc[b] - L) / (pc[b] - pc[b + 1])))
        }
        let contrast = Double(core / tau)
        let ok = yBot - yTop >= 6 && contrast >= 1.2
        return StickDetection(x: Double(xc) + 0.5, yTop: yTop, yBot: yBot, contrast: contrast,
                              usedFlagEdge: usedE, ok: ok)
    }

    private static func clampH(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return max(-0.5, min(0.5, v))
    }
}
