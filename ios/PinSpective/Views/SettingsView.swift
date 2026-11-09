import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    numberRow("Visible height (in)", $settings.flagHeightIn)
                    numberRow("Height uncertainty ± (in, 1σ)", $settings.flagSigmaIn)
                    numberRow("Base location ± (in, 1σ)", $settings.baseSigmaIn)
                } header: { Text("Flagstick") } footer: {
                    Text("Visible height = from the putting surface to the top of the stick, measured with a tape on the course you are testing. Flagsticks are not all the same height (7 ft and 8 ft are both common), so leave the uncertainty large until you have measured it. At 200 yd every inch of height error is about 2.4 yd of distance error.")
                }

                Section {
                    Stepper("Frames per measurement: \(settings.burstFrames)", value: $settings.burstFrames, in: 5...90, step: 5)
                    Stepper(String(format: "Refuse if 95%% range > ±%.0f%%", settings.maxRel95Pct), value: $settings.maxRel95Pct, in: 2...30, step: 1)
                    Stepper(String(format: "Need the stick in ≥ %.0f%% of frames", 100 * settings.minValidFraction), value: $settings.minValidFraction, in: 0.3...1.0, step: 0.1)
                    Stepper(String(format: "Uncalibrated lens ±%.1f%%", settings.uncalibratedFocalSigmaPct), value: $settings.uncalibratedFocalSigmaPct, in: 0.5...10, step: 0.5)
                } header: { Text("Measurement rules") } footer: {
                    Text("If the estimated 95% range is wider than the limit, the app shows “Measurement unavailable” instead of a number.")
                }

                Section("Test conditions (saved with each measurement)") {
                    TextField("Station label", text: $settings.station)
                    Picker("Lighting", selection: $settings.lighting) {
                        ForEach(AppSettings.lightingOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Background", selection: $settings.background) {
                        ForEach(AppSettings.backgroundOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Flagstick type (e.g. 8 ft yellow fiberglass)", text: $settings.flagType)
                }

                Section {
                    let fs = settings.focalScale(for: camera.info.uniqueKey)
                    LabeledContent("Combined k", value: fs.count > 0 ? String(format: "%.4f ± %.4f (%ld)", fs.k, fs.sigma, fs.count) : "not calibrated")
                    ForEach(settings.calibrations.filter { $0.cameraKey == camera.info.uniqueKey }) { c in
                        VStack(alignment: .leading) {
                            Text(String(format: "k = %.4f ± %.4f", c.k, c.sigmaK)).monospacedDigit()
                            Text(String(format: "%.1f in object at %.2f m · %ld frames · %.0f px · %@",
                                        c.objectHeightIn, c.distanceM, c.framesUsed, c.spanPx, c.date.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let mine = settings.calibrations.filter { $0.cameraKey == camera.info.uniqueKey }
                        let ids = Set(idx.map { mine[$0].id })
                        settings.calibrations.removeAll { ids.contains($0.id) }
                    }
                } header: { Text("Lens calibration") } footer: {
                    Text("k = true focal length ÷ the focal length the camera reports. Add calibrations from the main screen (Calibrate). Swipe to delete.")
                }

                Section("Camera diagnostics") {
                    let i = camera.info
                    LabeledContent("Camera", value: i.deviceName)
                    LabeledContent("Type", value: i.deviceType.replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: ""))
                    LabeledContent("Format", value: "\(i.width) × \(i.height)")
                    LabeledContent("Field of view", value: String(format: "%.2f°", i.fovDeg))
                    LabeledContent("fx from FOV", value: String(format: "%.0f px", i.fxFromFOV))
                    LabeledContent("fx from intrinsics", value: i.fxIntrinsic.map { String(format: "%.0f px", $0) } ?? "not delivered")
                    if let a = i.fxIntrinsic, i.fxFromFOV > 0 {
                        LabeledContent("Ratio", value: String(format: "%.4f", a / i.fxFromFOV))
                    }
                    LabeledContent("Principal point", value: i.cxIntrinsic.map { String(format: "%.0f, %.0f", $0, i.cyIntrinsic ?? 0) } ?? "—")
                    LabeledContent("Intrinsics delivery", value: i.intrinsicsDelivery ? "on" : "off")
                    LabeledContent("Video stabilization", value: i.stabilization)
                    LabeledContent("Distortion correction", value: i.distortionCorrection)
                    LabeledContent("Zoom factor", value: String(format: "%.2f (optical only)", i.zoomFactor))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func numberRow(_ title: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: v, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}

struct CalibrationSetupView: View {
    var onStart: (CalibrationInputs) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var heightIn = 84.0
    @State private var heightSigmaIn = 0.25
    @State private var distance = 100.0
    @State private var distanceSigma = 0.25
    @State private var unit = "ft"

    private func toM(_ v: Double) -> Double { unit == "m" ? v : unit == "ft" ? v * 0.3048 : v * metersPerYard }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Calibrate the lens on a thin, vertical object of known height at a distance you measured with a tape (not a laser reading of a test pin, which would make the accuracy test circular). A flagstick or painted pole on flat ground works. Use 25–60 yd so the object is large in the image, keep the base visible, and lock focus first.")
                        .font(.caption)
                }
                Section("Object") {
                    row("Visible height (in)", $heightIn)
                    row("Height ± (in, 1σ)", $heightSigmaIn)
                }
                Section("Horizontal distance from the phone") {
                    Picker("Unit", selection: $unit) { Text("ft").tag("ft"); Text("m").tag("m"); Text("yd").tag("yd") }
                        .pickerStyle(.segmented)
                    row("Distance (\(unit))", $distance)
                    row("Distance ± (\(unit), 1σ)", $distanceSigma)
                }
                Section {
                    Button("Start calibration") {
                        onStart(CalibrationInputs(heightM: heightIn * metersPerInch, sigmaHeightM: heightSigmaIn * metersPerInch,
                                                  distanceM: toM(distance), sigmaDistanceM: toM(distanceSigma)))
                        dismiss()
                    }
                    .disabled(heightIn <= 0 || distance <= 0)
                }
            }
            .navigationTitle("Lens calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ t: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(t)
            Spacer()
            TextField(t, value: v, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}

struct CalibrationResultView: View {
    let outcome: CalibrationOutcome
    let inputs: CalibrationInputs?
    let cameraKey: String
    var onDone: () -> Void
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let k = outcome.k, let s = outcome.sigmaK {
                    Section("Result") {
                        LabeledContent("k", value: String(format: "%.4f ± %.4f (1σ)", k, s))
                        LabeledContent("Implied focal length", value: String(format: "%.0f px", k * outcome.fxReported))
                        LabeledContent("Reported focal length", value: String(format: "%.0f px (%@)", outcome.fxReported, outcome.intrinsicsSource))
                        LabeledContent("Frames used", value: "\(outcome.framesUsed) of \(outcome.framesTotal)")
                        LabeledContent("Object in image", value: outcome.spanPx.map { String(format: "%.0f px", $0) } ?? "—")
                    }
                    if abs(k - 1) > 0.05 {
                        Section {
                            Text("k differs from 1 by more than 5%. That is larger than expected: check the object height, the distance, and that the lines were on the top and base.")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Button("Save calibration") {
                            if let i = inputs {
                                settings.calibrations.append(LensCalibration(
                                    cameraKey: cameraKey, k: k, sigmaK: s,
                                    objectHeightIn: i.heightM / metersPerInch, objectSigmaIn: i.sigmaHeightM / metersPerInch,
                                    distanceM: i.distanceM, distanceSigmaM: i.sigmaDistanceM,
                                    framesUsed: outcome.framesUsed, spanPx: outcome.spanPx ?? 0,
                                    fxReported: outcome.fxReported, intrinsicsSource: outcome.intrinsicsSource))
                            }
                            onDone(); dismiss()
                        }
                        Button("Discard and retry", role: .destructive) { dismiss() }
                        Button("Leave calibration mode") { onDone(); dismiss() }
                    }
                } else {
                    Section { Text(outcome.message).foregroundStyle(.orange) }
                    Section {
                        Button("Retry") { dismiss() }
                        Button("Leave calibration mode") { onDone(); dismiss() }
                    }
                }
            }
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
