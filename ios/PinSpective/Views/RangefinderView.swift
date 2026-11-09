import SwiftUI

struct CalibrationInputs {
    var heightM: Double
    var sigmaHeightM: Double
    var distanceM: Double
    var sigmaDistanceM: Double
}

struct RangefinderView: View {
    let motion: MotionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: MeasurementStore
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var engine: MeasurementEngine
    @Environment(\.scenePhase) private var phase

    @State private var bridge = PreviewBridge()
    @State private var sheet: Sheet?
    @State private var calInputs: CalibrationInputs?
    @State private var lastSaved: MeasurementRecord?

    enum Sheet: String, Identifiable { case log, stats, settings, calibrate; var id: String { rawValue } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session, bridge: bridge, overlay: engine.overlay)
                .ignoresSafeArea()
                .onTapGesture(count: 1, coordinateSpace: .local) { p in tap(p) }
                .overlay(Reticle().allowsHitTesting(false).ignoresSafeArea())

            VStack(spacing: 8) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let img = engine.loupe {
                HStack { Spacer(); Loupe(image: img, lines: engine.loupeLines) }
                    .padding(.trailing, 10)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .log: LogView()
            case .stats: StatsView()
            case .settings: SettingsView()
            case .calibrate: CalibrationSetupView { inputs in calInputs = inputs }
            }
        }
        .background(
            Color.clear.sheet(item: $engine.burstResult) { r in
                ResultView(result: r) { rec in lastSaved = rec }
            }
        )
        .background(
            Color.clear.sheet(item: $engine.calibrationOutcome) { o in
                CalibrationResultView(outcome: o, inputs: calInputs, cameraKey: camera.info.uniqueKey) {
                    calInputs = nil
                }
            }
        )
        .onAppear {
            motion.start()
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true
            engine.setLiveConfig(makeCfg())
        }
        .onChange(of: phase) { _, p in
            if p == .active { camera.start(); motion.start() } else if p == .background { camera.stop(); motion.stop() }
        }
        .onReceive(settings.objectWillChange) { _ in
            DispatchQueue.main.async { engine.setLiveConfig(makeCfg()) }
        }
        .onChange(of: camera.info.uniqueKey) { _, _ in engine.setLiveConfig(makeCfg()) }
    }

    // MARK: top

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Chip(text: camera.info.isTelephoto ? "5× optical" : (camera.ready ? "Not telephoto" : "…"),
                     color: camera.info.isTelephoto ? .green : .orange)
                let fs = settings.focalScale(for: camera.info.uniqueKey)
                Chip(text: fs.count > 0 ? String(format: "Lens cal ±%.1f%%", 100 * fs.sigma / fs.k)
                                        : String(format: "Lens uncal. ±%.0f%%", settings.uncalibratedFocalSigmaPct),
                     color: fs.count > 0 ? .green : .orange)
                Chip(text: String(format: "Flag %.0f±%.1f in", settings.flagHeightIn, settings.flagSigmaIn),
                     color: settings.flagSigmaIn <= 1 ? .green : .orange)
                Chip(text: String(format: "Roll %.1f°", engine.rollDeg), color: abs(engine.rollDeg) < 3 ? .green : .orange)
            }
            Text(camera.state).font(.caption2).foregroundStyle(.secondary)
            if let c = calInputs {
                Text(String(format: "CALIBRATION MODE · object %.1f in at %.2f m — aim at it and press Capture",
                            c.heightM / metersPerInch, c.distanceM))
                    .font(.caption.bold()).foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: bottom

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let m = engine.lostMessage {
                Text(m).font(.footnote).foregroundStyle(.orange)
            } else if !engine.liveText.isEmpty {
                Text(engine.liveText).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            } else if !engine.locked {
                Text("Put the reticle on the flag and press Lock, or tap the flagstick.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let r = lastSaved { LastResultLine(record: r) }

            HStack(spacing: 12) {
                Button(engine.locked ? "Unlock" : "Lock") {
                    if engine.locked { engine.unlock() } else { engine.lockAtCenter() }
                }
                .buttonStyle(.bordered)

                Button(action: capture) {
                    VStack(spacing: 2) {
                        if engine.capturing {
                            ProgressView(value: engine.progress).tint(.white).frame(width: 110)
                            Text("Hold steady…").font(.caption)
                        } else {
                            Text(calInputs == nil ? "Measure" : "Capture").font(.title3.bold())
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(calInputs == nil ? .green : .yellow)
                .disabled(engine.capturing || !camera.ready)

                Button {
                    camera.setFocusLocked(!camera.focusLocked)
                } label: {
                    Image(systemName: camera.focusLocked ? "lock.fill" : "camera.metering.center.weighted")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(camera.focusLocked ? "Unlock focus" : "Lock focus")
            }

            HStack {
                toolButton("list.bullet", "Log") { sheet = .log }
                toolButton("chart.bar", "Stats") { sheet = .stats }
                toolButton("scope", calInputs == nil ? "Calibrate" : "Cancel cal") {
                    if calInputs == nil { sheet = .calibrate } else { calInputs = nil }
                }
                toolButton("gearshape", "Settings") { sheet = .settings }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func toolButton(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon); Text(title).font(.caption2) }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    // MARK: actions

    private func tap(_ p: CGPoint) {
        guard camera.info.width > 0, !engine.capturing,
              let b = bridge.bufferPoint(fromViewPoint: p, bufferW: camera.info.width, bufferH: camera.info.height) else { return }
        engine.lock(atBuffer: b)
        if let d = bridge.devicePoint(fromViewPoint: p) { camera.focus(at: d) }
    }

    private func makeCfg() -> EstimateConfig {
        let fs = settings.focalScale(for: camera.info.uniqueKey)
        return EstimateConfig(heightM: settings.flagHeightIn * metersPerInch,
                              sigmaHeightM: settings.flagSigmaIn * metersPerInch,
                              sigmaBaseM: settings.baseSigmaIn * metersPerInch,
                              k: fs.k, sigmaKRel: fs.sigma / fs.k,
                              maxRel95: settings.maxRel95Pct / 100,
                              minValidFraction: settings.minValidFraction)
    }

    private func capture() {
        let fs = settings.focalScale(for: camera.info.uniqueKey)
        let meta = (name: camera.info.deviceName, key: camera.info.uniqueKey, k: fs.k, sigK: fs.sigma,
                    count: fs.count, focusLocked: camera.focusLocked)
        if let c = calInputs {
            // calibration solves for k, so measure with k = 1
            var cfg = makeCfg(); cfg.k = 1
            engine.startBurst(.calibrate(heightM: c.heightM, sigmaHeightM: c.sigmaHeightM,
                                         distanceM: c.distanceM, sigmaDistanceM: c.sigmaDistanceM),
                              cfg: cfg, frames: max(30, settings.burstFrames), meta: meta)
        } else {
            engine.startBurst(.measure, cfg: makeCfg(), frames: settings.burstFrames, meta: meta)
        }
    }
}

// MARK: small views

struct Chip: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption2.bold()).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Reticle: View {
    var body: some View {
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            Path { p in
                p.move(to: CGPoint(x: c.x - 40, y: c.y)); p.addLine(to: CGPoint(x: c.x - 8, y: c.y))
                p.move(to: CGPoint(x: c.x + 8, y: c.y)); p.addLine(to: CGPoint(x: c.x + 40, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - 40)); p.addLine(to: CGPoint(x: c.x, y: c.y - 8))
                p.move(to: CGPoint(x: c.x, y: c.y + 8)); p.addLine(to: CGPoint(x: c.x, y: c.y + 40))
            }
            .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
        }
    }
}

/// Magnified, gravity-aligned view of the region being analysed, with the detected top (red)
/// and base (blue). Display only; it plays no part in the measurement.
struct Loupe: View {
    let image: CGImage
    let lines: (top: Double, base: Double, x: Double)?
    var body: some View {
        let h: CGFloat = 300
        let w = h * CGFloat(image.width) / CGFloat(image.height)
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none).frame(width: w, height: h)
            if let l = lines {
                Rectangle().fill(Color.red).frame(width: w, height: 1.5).offset(y: CGFloat(l.top) * h)
                Rectangle().fill(Color.blue).frame(width: w, height: 1.5).offset(y: CGFloat(l.base) * h)
            }
        }
        .frame(width: w, height: h)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.6)))
    }
}

struct LastResultLine: View {
    let record: MeasurementRecord
    var body: some View {
        HStack {
            if record.status == "ok", let e = record.estimateYd {
                Text("Last: \(Fmt.yd(e)) ± \(Fmt.yd(record.halfWidth95Yd)) yd")
            } else {
                Text(record.status == "rejected-lines" ? "Last: rejected (lines wrong)" : "Last: measurement unavailable")
            }
            if let a = record.actualYd { Text("· laser \(Fmt.yd1(a))") }
            if let err = record.errorYd { Text("· err \(Fmt.signed(err))") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
