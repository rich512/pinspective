import SwiftUI

struct LogView: View {
    @EnvironmentObject var store: MeasurementStore
    @Environment(\.dismiss) private var dismiss
    @State private var csvURL: URL?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty {
                    Text("No measurements yet.").foregroundStyle(.secondary)
                }
                ForEach(store.records) { r in
                    NavigationLink { RecordEditView(record: r) } label: { RecordRow(record: r) }
                }
                .onDelete { idx in store.records.remove(atOffsets: idx) }
            }
            .navigationTitle("Log (\(store.records.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let u = csvURL {
                        ShareLink(item: u) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete all", role: .destructive) { confirmClear = true }.disabled(store.records.isEmpty)
                }
            }
            .confirmationDialog("Delete every measurement? Export the CSV first if you need it.",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.records.removeAll() }
            }
            .onAppear { csvURL = store.exportCSV() }
            .onChange(of: store.records.count) { _, _ in csvURL = store.exportCSV() }
        }
    }
}

struct RecordRow: View {
    let record: MeasurementRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                switch record.status {
                case "ok":
                    Text("\(Fmt.yd1(record.estimateYd)) ± \(Fmt.yd1(record.halfWidth95Yd)) yd").bold().monospacedDigit()
                case "rejected-lines":
                    Text("Rejected (lines wrong)").foregroundStyle(.orange)
                default:
                    Text("Unavailable").foregroundStyle(.orange)
                }
                Spacer()
                if let a = record.actualYd { Text("laser \(Fmt.yd1(a))").monospacedDigit() }
            }
            HStack {
                Text(record.timestamp, style: .time)
                Text(record.reportedMethod)
                if !record.station.isEmpty { Text(record.station) }
                Spacer()
                if let e = record.errorYd {
                    Text("err \(Fmt.signed(e))").monospacedDigit()
                        .foregroundStyle(record.within95 == true ? .green : .orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if record.status == "unavailable", let why = record.unavailableReason {
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Lets the tester add or correct the laser distance and notes after the fact. The camera
/// estimate itself cannot be edited.
struct RecordEditView: View {
    @EnvironmentObject var store: MeasurementStore
    @State var record: MeasurementRecord
    @State private var actualText = ""

    var body: some View {
        Form {
            Section("Result") {
                LabeledContent("Status", value: record.status)
                LabeledContent("Method", value: record.reportedMethod)
                LabeledContent("Estimate", value: record.status == "ok" ? "\(Fmt.yd1(record.estimateYd)) yd" : "—")
                LabeledContent("95% ±", value: record.status == "ok" ? "\(Fmt.yd1(record.halfWidth95Yd)) yd" : "—")
                if let w = record.unavailableReason { Text(w).font(.caption) }
                LabeledContent("A single", value: Fmt.yd1(record.aDistanceYd) + (record.aAvailable ? "" : " (unavail.)"))
                LabeledContent("C multi", value: Fmt.yd1(record.cDistanceYd) + (record.cAvailable ? "" : " (unavail.)"))
                LabeledContent("Stick height in image", value: record.spanPxMedian.map { String(format: "%.1f px", $0) } ?? "—")
                LabeledContent("Frames", value: "\(record.framesValid)/\(record.framesTotal)")
            }
            Section("Ground truth") {
                TextField("Laser distance (yd)", text: $actualText).keyboardType(.decimalPad)
                TextField("Station", text: $record.station)
                TextField("Notes", text: $record.notes)
                if let e = record.errorYd { LabeledContent("Error", value: Fmt.signed(e) + " yd") }
            }
        }
        .navigationTitle("Measurement")
        .onAppear { actualText = record.actualYd.map { String(format: "%.1f", $0) } ?? "" }
        .onChange(of: actualText) { _, t in
            record.actualYd = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        }
        .onDisappear { store.update(record) }
    }
}
