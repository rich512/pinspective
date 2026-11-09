import SwiftUI

struct StatsView: View {
    @EnvironmentObject var store: MeasurementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rs = store.records
        let withTruth = rs.filter { $0.actualYd != nil }.count
        NavigationStack {
            List {
                Section {
                    Text("Target: ±3–5 yd at 200 yd. This is an experimental goal, not an assumed capability. Only attempts with a laser distance count. Errors are app minus laser (+ = reads long).")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(withTruth) of \(rs.count) logged attempts have a laser distance.").font(.caption)
                }
                Section("By distance") {
                    ForEach(AccuracyReport.byDistance(rs), id: \.label) { MetricsCard(m: $0, full: true) }
                }
                Section("All distances") {
                    MetricsCard(m: AccuracyMetrics(label: "Overall", records: rs), full: true)
                }
                Section("Same attempts, each method") {
                    ForEach(AccuracyReport.byMethod(rs), id: \.label) { MetricsCard(m: $0, full: false) }
                }
                Section("By lighting") {
                    ForEach(AccuracyReport.byField(rs) { $0.lighting }, id: \.label) { MetricsCard(m: $0, full: true) }
                }
                Section("By background") {
                    ForEach(AccuracyReport.byField(rs) { $0.background }, id: \.label) { MetricsCard(m: $0, full: true) }
                }
                Section("By flagstick type") {
                    ForEach(AccuracyReport.byField(rs) { $0.flagType }, id: \.label) { MetricsCard(m: $0, full: true) }
                }
            }
            .navigationTitle("Accuracy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct MetricsCard: View {
    let m: AccuracyMetrics
    let full: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.label).bold()
                Spacer()
                if full {
                    Text("success \(m.successes)/\(m.attempts) (\(Fmt.pct(m.successRate)))").font(.caption)
                } else {
                    Text("n = \(m.n)").font(.caption)
                }
            }
            if m.n == 0 {
                Text("No results with a laser distance yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { Text("Mean abs error"); Text("\(Fmt.yd1(m.mae)) yd") }
                    GridRow { Text("Median error"); Text("\(Fmt.signed(m.medianError)) yd  (abs \(Fmt.yd1(m.medianAbsError)))") }
                    GridRow { Text("90th pct abs error"); Text("\(Fmt.yd1(m.p90AbsError)) yd") }
                    GridRow { Text("Bias (mean error)"); Text("\(Fmt.signed(m.meanError)) yd") }
                    GridRow { Text("RMS error"); Text("\(Fmt.yd1(m.rmse)) yd") }
                    if full {
                        GridRow { Text("Inside 95% range"); Text("\(Fmt.pct(m.coverage95))  (should be ~95%)") }
                        GridRow { Text("Repeatability (SD)"); Text(m.repeatabilitySD.map { String(format: "%.1f yd over %ld groups", $0, m.repeatGroups) } ?? "need ≥2 repeats at one station") }
                        GridRow { Text("Median time to result"); Text(m.medianTimeS.map { String(format: "%.1f s", $0) } ?? "—") }
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 2)
    }
}
