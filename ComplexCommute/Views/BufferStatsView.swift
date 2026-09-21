import CommuteCore
import SwiftData
import SwiftUI

/// What the app has learned about the time this rider really has in hand at their connections, and
/// the buffer that would cover four days in five.
struct BufferStatsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(StationBuffer.key) private var bufferMinutes = StationBuffer.defaultMinutes
    @Query(sort: \ConnectionLog.date, order: .reverse) private var log: [ConnectionLog]

    private var records: [ConnectionRecord] { log.map(\.record) }

    var body: some View {
        Form {
            Section {
                Stepper(value: $bufferMinutes, in: StationBuffer.range) {
                    LabeledContent("Station Buffer", value: bufferMinutes == 0 ? "None" : "\(bufferMinutes) min")
                }
                suggestion
            } header: {
                Text("Buffer")
            } footer: {
                Text("Trips are planned around connections that leave you at least this long between reaching a platform and your train or bus leaving.")
            }

            if let stats = BufferLearning.stats(for: records) {
                Section {
                    LabeledContent("Connections", value: "\(stats.sampleCount)")
                    LabeledContent("Average in Hand", value: measure(stats.averageTimeInHand))
                    LabeledContent("Tightest", value: measure(stats.shortestTimeInHand))
                    if stats.missCount > 0 {
                        LabeledContent("Missed", value: "\(stats.missCount)")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Overall")
                } footer: {
                    Text("Recorded as you travel: the time between reaching a platform and your vehicle actually leaving.")
                }
            }

            let groups = BufferLearning.groups(from: records)
            if !groups.isEmpty {
                Section("By Connection") {
                    ForEach(groups) { group in
                        NavigationLink {
                            ConnectionHistoryView(group: group, delete: delete)
                        } label: {
                            GroupRow(group: group)
                        }
                    }
                }

                Section {
                    Button("Forget Everything Learned", systemImage: "trash", role: .destructive) {
                        log.forEach(modelContext.delete)
                        try? modelContext.save()
                    }
                }
            } else {
                Section {
                    Label("Nothing learned yet", systemImage: "chart.bar")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Take a trip with Go and the app starts timing your connections.")
                }
            }
        }
        .navigationTitle("Buffers")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var suggestion: some View {
        if let safe = BufferLearning.suggestedBufferMinutes(from: records) {
            let clamped = min(max(safe, StationBuffer.range.lowerBound), StationBuffer.range.upperBound)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe Buffer \(clamped) min")
                        .font(.headline)
                    Text("Covers 4 of your last 5 connections in \(records.count) recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(bufferMinutes == clamped ? "In Use" : "Use") { bufferMinutes = clamped }
                    .buttonStyle(.bordered)
                    .disabled(bufferMinutes == clamped)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("After \(BufferLearning.minimumSamples) recorded connections the app can suggest a buffer that covers 80% of them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func delete(_ record: ConnectionRecord) {
        log.filter { $0.recordID == record.id }.forEach(modelContext.delete)
        try? modelContext.save()
    }

    private func measure(_ seconds: TimeInterval) -> String {
        BufferStatsView.measure(seconds)
    }

    /// Time in hand goes negative when a vehicle left before the rider got there, which "1 min" would hide.
    static func measure(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        return seconds < -30 ? "\(minutes) min short" : "\(minutes) min"
    }
}

private struct GroupRow: View {
    let group: ConnectionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.stationName)
                .font(.headline)
            Text("\(group.approach.label) · \(group.records.count) recorded")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(BufferStatsView.measure(group.stats.averageTimeInHand), systemImage: "hourglass")
                if group.stats.isConfident {
                    Label("\(group.stats.safeBufferMinutes) min safe", systemImage: "shield.lefthalf.filled")
                }
                if group.stats.missCount > 0 {
                    Label("\(group.stats.missCount)", systemImage: "figure.wave")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every recorded connection at one platform, so a day that went nothing like the others can be dropped.
private struct ConnectionHistoryView: View {
    let group: ConnectionGroup
    let delete: (ConnectionRecord) -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Average in Hand", value: BufferStatsView.measure(group.stats.averageTimeInHand))
                LabeledContent("Tightest", value: BufferStatsView.measure(group.stats.shortestTimeInHand))
                if group.stats.isConfident {
                    LabeledContent("Safe Buffer", value: "\(group.stats.safeBufferMinutes) min")
                } else {
                    LabeledContent("Safe Buffer", value: "needs \(BufferLearning.minimumSamples - group.stats.sampleCount) more")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(group.approach == .change
                     ? "Changes underground can't be watched, so these come from the agency's own account of the trains."
                     : "Timed from when you reached the platform to when your vehicle left.")
            }

            Section("Trips") {
                ForEach(group.records) { record in
                    RecordRow(record: record)
                }
                .onDelete { offsets in
                    offsets.map { group.records[$0] }.forEach(delete)
                }
            }
        }
        .navigationTitle(group.stationName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecordRow: View {
    let record: ConnectionRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.date, format: .dateTime.weekday().month().day())
                    .font(.subheadline)
                Text("\(record.routeName.map { "\($0) · " } ?? "")planned \(Int(record.plannedBuffer / 60)) min in hand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record.wasMissed {
                Label("Missed", systemImage: "figure.wave")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(BufferStatsView.measure(record.timeInHand))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(record.timeInHand < 60 ? Color.orange : Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
