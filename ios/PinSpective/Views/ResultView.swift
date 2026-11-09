import SwiftUI

/// Shown after every burst: the estimate (or "Measurement unavailable"), the frozen frame with the
/// detected top and base for checking, manual line adjustment, and the laser ground truth.
struct ResultView: View {
    let result: BurstResult
    var onSaved: (MeasurementRecord) -> Void

    @EnvironmentObject var store: MeasurementStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var topV = 0.0
    @State private var baseV = 0.0
    @State private var autoTop = 0.0
    @State private var autoBase = 0.0
    @State private var u = 0.0
    @State private var cropRect = CGRect.zero
    @State private var cropImage: CGImage?
    @State private var linesMoved = false
    @State private var useManual = false
    @State private var linesCheck = "not-checked"   // not-checked | correct | wrong
    private var linesWrong: Bool { linesCheck == "wrong" }
    @State private var actualText = ""
    @State private var station = ""
    @State private var notes = ""
    @State private var dragStart: Double?
    @State private var selected = 0   // 0 = top, 1 = base

    private var reviewFrame: FrameSample? {
        guard let i = result.reviewIndex, i < result.frames.count else { return nil }
        return result.frames[i]
    }
    private var manual: MethodEstimate? {
        guard linesMoved, let f = reviewFrame else { return nil }
        return DistanceEstimator.manual(f, topV: topV, baseV: baseV, u: u, cfg: result.cfg)
    }
    private var shown: MethodEstimate { (useManual ? manual : nil) ?? result.multi }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline
                    methodSummary
                    reviewSection
                    groundTruthSection
                    Button(action: save) {
                        Text("Save to log").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Save every attempt, including unavailable ones and wrong lines, so the success rate is honest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
        .onAppear(perform: setup)
    }

    // MARK: sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            if linesWrong && !useManual {
                Text("Rejected").font(.largeTitle.bold()).foregroundStyle(.orange)
                Text("You marked the detected lines as wrong.").foregroundStyle(.secondary)
            } else if shown.available, let d = shown.distanceYd, let h = shown.halfWidth95Yd {
                Text("\(Fmt.yd(d)) yd").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                Text("95% range \(Fmt.yd(d - h))–\(Fmt.yd(d + h)) yd  (± \(Fmt.yd1(h)))").font(.headline)
                Text(methodName(shown)).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Measurement unavailable").font(.title.bold()).foregroundStyle(.orange)
                Text(shown.reason ?? "No defensible distance could be calculated.").foregroundStyle(.secondary)
                Text(methodName(shown)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.yellow)
            }
        }
    }

    private var methodSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All methods on this burst").font(.headline)
            row("C multi-frame", result.multi)
            row("A single frame", result.single)
            if let m = manual { row("A manual lines", m) }
            let cfg = result.cfg
            Text(String(format: "Uncertainty parts (1σ): image %.2f%% · flag height %.2f%% · base %.2f%% · lens %.2f%%",
                        100 * (shown.relRandom ?? 0), 100 * cfg.relHeight, 100 * cfg.relBase, 100 * cfg.sigmaKRel))
                .font(.caption).foregroundStyle(.secondary)
            Text(String(format: "Frames: %ld of %ld found the stick · burst %.1f s · %.1f s from lock to result",
                        result.frames.filter { $0.det?.ok == true }.count, result.frames.count,
                        result.burstDurationS, result.timeToResultS))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ e: MethodEstimate) -> some View {
        HStack {
            Text(name).frame(width: 120, alignment: .leading)
            if e.available, let d = e.distanceYd {
                Text("\(Fmt.yd1(d)) ± \(Fmt.yd1(e.halfWidth95Yd)) yd").monospacedDigit()
            } else {
                Text("unavailable").foregroundStyle(.orange)
            }
            Spacer()
            Text(e.spanPx.map { String(format: "%.1f px", $0) } ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check the lines").font(.headline)
            Text("Red = top of the stick, blue = where it meets the green. Drag a line or use the nudge buttons if it's off.")
                .font(.caption).foregroundStyle(.secondary)
            if let img = cropImage, cropRect.height > 0 {
                let ch = Double(cropRect.height), cw = Double(cropRect.width)
                let dispH: CGFloat = 360
                let dispW = min(300, dispH * CGFloat(cw / ch))
                let realH = dispW < dispH * CGFloat(cw / ch) ? dispW * CGFloat(ch / cw) : dispH
                HStack {
                    Spacer()
                    ZStack(alignment: .topLeading) {
                        Image(decorative: img, scale: 1).resizable().interpolation(.none)
                            .frame(width: dispW, height: realH)
                        line(v: topV, color: .red, which: 0, w: dispW, h: realH, ch: ch)
                        line(v: baseV, color: .blue, which: 1, w: dispW, h: realH, ch: ch)
                    }
                    .frame(width: dispW, height: realH)
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
                    Spacer()
                }
                HStack {
                    Picker("Line", selection: $selected) { Text("Top").tag(0); Text("Base").tag(1) }
                        .pickerStyle(.segmented).frame(width: 140)
                    Button { nudge(-0.25) } label: { Image(systemName: "arrow.up") }.buttonStyle(.bordered)
                    Button { nudge(0.25) } label: { Image(systemName: "arrow.down") }.buttonStyle(.bordered)
                    Button("Reset") { topV = autoTop; baseV = autoBase; linesMoved = false; useManual = false }
                        .buttonStyle(.bordered)
                }
                .font(.caption)
                Toggle("Report my adjusted lines (Method A manual)", isOn: $useManual).disabled(!linesMoved)
                Picker("Detected lines", selection: $linesCheck) {
                    Text("Not checked").tag("not-checked"); Text("Correct").tag("correct"); Text("Wrong").tag("wrong")
                }
                .pickerStyle(.segmented)
                Text("“Wrong” rejects the attempt (it still counts as a failure in the success rate). Automatic detection can lock onto tree texture, so check every time.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No frame with a detected flagstick to review.").foregroundStyle(.secondary)
            }
        }
    }

    private func line(v: Double, color: Color, which: Int, w: CGFloat, h: CGFloat, ch: Double) -> some View {
        let y = CGFloat((v - Double(cropRect.minY)) / ch) * h
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(color).frame(width: w, height: 1.5).offset(y: y)
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: w, height: 36).offset(y: y - 18)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = which == 0 ? topV : baseV; selected = which }
                        let nv = dragStart! + Double(g.translation.height / h) * ch
                        if which == 0 { topV = nv } else { baseV = nv }
                        linesMoved = true
                    }
                    .onEnded { _ in dragStart = nil })
        }
    }

    private func nudge(_ px: Double) {
        if selected == 0 { topV += px } else { baseV += px }
        linesMoved = true
    }

    private var groundTruthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ground truth").font(.headline)
            TextField("Laser rangefinder distance (yd)", text: $actualText)
                .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
            if let a = parsedActual, shown.available, !(linesWrong && !useManual), let d = shown.distanceYd {
                let err = d - a
                let inside = abs(err) <= (shown.halfWidth95Yd ?? 0)
                Text(String(format: "Error %+.1f yd (%+.1f%%) · %@", err, 100 * err / a,
                            inside ? "inside the 95% range" : "OUTSIDE the 95% range"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(inside ? .green : .orange)
            }
            TextField("Station label (e.g. Range pin 3)", text: $station).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $notes).textFieldStyle(.roundedBorder)
        }
    }

    private var parsedActual: Double? {
        Double(actualText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func methodName(_ e: MethodEstimate) -> String {
        switch e.method {
        case "C-multi-frame": return "Method C: known flagstick height, \(e.nUsed) of \(e.nTotal) frames combined"
        case "A-single-frame": return "Method A: known flagstick height, single frame"
        case "A-manual": return "Method A: known flagstick height, your adjusted lines"
        default: return e.method
        }
    }

    // MARK: setup / save

    private func setup() {
        station = settings.station
        guard let roi = result.reviewROI else { return }
        if let f = reviewFrame, let d = f.det {
            topV = d.yTop; baseV = d.yBot; u = d.x
        } else {
            topV = Double(roi.h) * 0.3; baseV = Double(roi.h) * 0.7; u = Double(roi.w) / 2
        }
        autoTop = topV; autoBase = baseV
        let span = max(20, baseV - topV)
        let y0 = max(0, topV - 0.3 * span - 20), y1 = min(Double(roi.h), baseV + 0.3 * span + 20)
        let cw = min(Double(roi.w), max(80, (y1 - y0) * 0.4))
        let x0 = min(max(0, u - cw / 2), Double(roi.w) - cw)
        cropRect = CGRect(x: x0, y: y0, width: cw, height: y1 - y0).integral
        cropImage = ROISampler.makeImage(roi, crop: cropRect)
    }

    private func save() {
        var r = MeasurementRecord(status: "", reportedMethod: "")
        let a = result.single, c = result.multi, cfg = result.cfg
        let e = shown
        r.actualYd = parsedActual
        r.station = station
        r.notes = notes
        r.reportedMethod = e.method
        r.linesCheck = useManual ? "manual" : linesCheck
        if linesWrong && !useManual {
            r.status = "rejected-lines"
        } else if e.available {
            r.status = "ok"
            r.estimateYd = e.distanceYd
            r.sigmaYd = e.sigmaYd
            r.halfWidth95Yd = e.halfWidth95Yd
        } else {
            r.status = "unavailable"
            r.unavailableReason = e.reason
        }
        r.warnings = e.warnings.joined(separator: "; ")
        r.aDistanceYd = a.distanceYd; r.aSigmaYd = a.sigmaYd; r.aAvailable = a.available
        r.cDistanceYd = c.distanceYd; r.cSigmaYd = c.sigmaYd; r.cAvailable = c.available
        if let m = manual { r.manualDistanceYd = m.distanceYd; r.manualSigmaYd = m.sigmaYd; r.manualAvailable = m.available }
        r.relRandom = e.relRandom
        r.relHeight = cfg.relHeight; r.relBase = cfg.relBase; r.relFocal = cfg.sigmaKRel

        let valid = result.frames.compactMap { $0.det?.ok == true ? $0.det : nil }
        r.framesTotal = result.frames.count
        r.framesValid = valid.count
        r.framesUsed = c.nUsed
        if !valid.isEmpty {
            r.spanPxMedian = Stats.median(valid.map { $0.span })
            r.spanPxSD = Stats.sd(valid.map { $0.span })
            r.contrastMedian = Stats.median(valid.map { $0.contrast })
        }
        r.flagEdgeFraction = Double(valid.filter { $0.usedFlagEdge }.count) / Double(max(1, valid.count))

        let f = reviewFrame ?? result.frames.first
        r.cameraDevice = result.cameraName
        if let f {
            r.bufferW = f.geo.bufferW; r.bufferH = f.geo.bufferH
            r.fx = f.geo.fx; r.fy = f.geo.fy; r.cx = f.geo.cx; r.cy = f.geo.cy
            r.intrinsicsSource = f.intrinsicsSource
            r.lensPosition = Double(f.lensPosition); r.iso = Double(f.iso); r.exposureMs = f.exposureS * 1000
            r.pitchDeg = f.geo.pitchDeg; r.rollDeg = f.geo.rollDeg
        }
        r.focalK = result.focalK; r.focalKSigma = result.focalKSigma; r.calibrationCount = result.calibrationCount
        r.focusLocked = result.focusLocked
        r.pitchJitterDeg = result.pitchJitterDeg
        r.flagHeightIn = cfg.heightM / metersPerInch
        r.flagSigmaIn = cfg.sigmaHeightM / metersPerInch
        r.baseSigmaIn = cfg.sigmaBaseM / metersPerInch
        r.lighting = settings.lighting; r.background = settings.background; r.flagType = settings.flagType
        r.timeToResultS = result.timeToResultS
        r.burstDurationS = result.burstDurationS
        r.processingMsMedian = Stats.median(result.frames.map { $0.processingMs })

        settings.station = station
        store.add(r)
        onSaved(r)
        dismiss()
    }
}
