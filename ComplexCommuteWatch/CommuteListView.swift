import CommuteCore
import SwiftUI

/// Saved commutes, each one tap from being planned and started on the phone.
struct CommuteListView: View {
    let phone: PhoneLink

    var body: some View {
        List {
            if phone.context.commutes.isEmpty {
                ContentUnavailableView("No Commutes", systemImage: "tram.fill",
                                       description: Text("Save a commute in Commute on your iPhone to start it from here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(phone.context.commutes) { commute in
                Button {
                    Task { await phone.send(.start(commuteID: commute.id)) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(commute.name)
                                .font(.headline)
                            if phone.busy == .start(commuteID: commute.id) {
                                Spacer(minLength: 0)
                                ProgressView()
                                    .frame(width: 20, height: 20)
                            }
                        }
                        if let arriveBy = commute.arriveBy {
                            Label("by \(arriveBy.formatted(date: .omitted, time: .shortened))", systemImage: "target")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(commute.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .disabled(phone.busy != nil)
            }
            if !phone.isReachable, !phone.context.commutes.isEmpty {
                Label("iPhone not in reach", systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Commute")
    }
}
