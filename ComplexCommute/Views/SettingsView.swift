import GTFSKit
import SwiftUI

struct SettingsView: View {
    @Environment(TransitDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StationBuffer.key) private var bufferMinutes = StationBuffer.defaultMinutes
    @AppStorage(DirectionsApp.key) private var directionsApp = DirectionsApp.appleMaps

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        BufferStatsView()
                    } label: {
                        LabeledContent("Station Buffer", value: bufferMinutes == 0 ? "None" : "\(bufferMinutes) min")
                    }
                    NotificationRow()
                } header: {
                    Text("Planning")
                } footer: {
                    Text("Time to have in hand when you reach a station and every time you change trains or buses. The app times your real connections as you travel and can suggest a buffer that covers them.")
                }

                Section {
                    Picker("Directions In", selection: $directionsApp) {
                        ForEach(DirectionsApp.allCases) { app in
                            Text(app.name).tag(app)
                        }
                    }
                } footer: {
                    Text("Drives and walks are handed to this app for turn-by-turn directions. Commute keeps following the trip in the background and on your Lock Screen.")
                }

                Section {
                    ForEach(TransitRegion.allCases) { region in
                        RegionRow(region: region)
                    }
                } header: {
                    Text("Cities")
                } footer: {
                    Text("Each city downloads with all of its services, so any trip there can use them. Leave out ones you'd rather not ride when planning a trip. Schedules are stored on this iPhone so routes can be planned without a server, and take several times their download size once installed.")
                }

                Section {
                    ForEach(APIKeyID.allCases) { key in
                        NavigationLink {
                            APIKeyView(key: key)
                        } label: {
                            LabeledContent(key.name, value: store.apiKey(key) == nil ? "Not Set" : "Added")
                        }
                    }
                } header: {
                    Text("API Keys")
                } footer: {
                    Text("Some agencies only share data with registered developers. Keys are free and stay in this iPhone's keychain.")
                }

                Section {
                    NavigationLink("Data Sources") {
                        DataSourcesView()
                    }
                } footer: {
                    Text("Transit information comes from the agencies' public data. ComplexCommute isn't affiliated with or endorsed by any of them.")
                }
            }
            .navigationTitle("Transit Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// Says whether the app may raise a notification, since a "no" quietly turns off the time-to-leave
/// reminder and the offer of a faster train.
private struct NotificationRow: View {
    @Environment(TripNotifier.self) private var notifier

    var body: some View {
        switch notifier.authorization {
        case .authorized, .provisional, .ephemeral:
            LabeledContent("Trip Notifications", value: "On")
        case .notDetermined:
            LabeledContent("Trip Notifications", value: "Asked when you start a trip")
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    LabeledContent("Trip Notifications", value: "Off")
                }
            }
        }
    }
}

/// A whole city: downloaded, updated and removed as one.
private struct RegionRow: View {
    let region: TransitRegion
    @Environment(TransitDataStore.self) private var store

    private var feeds: [FeedDescriptor] { FeedCatalog.feeds(in: region) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(region.name)
                Text(feeds.map(\.name).formatted(.list(type: .and)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                status
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
        .accessibilityElement(children: .combine)
    }

    private func megabytes(_ mb: Double) -> String {
        Int64(mb * 1_000_000).formatted(.byteCount(style: .file))
    }

    @ViewBuilder
    private var status: some View {
        if let progress = store.progress(of: region) {
            ProgressView(value: progress) {
                Text("Downloading… \(progress, format: .percent.precision(.fractionLength(0)))")
            }
        } else if let failure = store.regionFailures[region] {
            Text("Couldn't download. \(failure)")
                .foregroundStyle(.red)
        } else {
            switch store.state(of: region) {
            case .installed:
                let infos = feeds.compactMap { store.installed[$0.id] }
                if let expired = infos.first(where: { $0.isExpired() }), let feed = FeedCatalog.feed(id: expired.feedID) {
                    Text("\(feed.name)'s published schedule has ended. Using its final week until they post an update.")
                        .foregroundStyle(Color.warningText)
                } else if let oldest = infos.map(\.importedAt).min() {
                    Text("\(store.installedBytes(of: region), format: .byteCount(style: .file)) · Updated \(oldest, format: .dateTime.month().day())")
                }
            case .incomplete:
                Text("Some services are missing · \(megabytes(store.remainingMB(for: region))) to finish")
            case .notInstalled:
                if let key = FeedCatalog.requiredKeys(for: region).first, store.isMissingKey(for: region) {
                    Text("Requires a \(key.name) API key · About \(megabytes(FeedCatalog.downloadMB(for: region)))")
                } else {
                    Text("About \(megabytes(FeedCatalog.downloadMB(for: region))) download")
                }
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if store.isInstalling(region) {
            Button("Cancel", systemImage: "stop.circle") { store.cancel(region) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        } else {
            switch store.state(of: region) {
            case .installed:
                Menu {
                    Button("Update Now", systemImage: "arrow.down.circle") { store.install(region, updatingAll: true) }
                        .disabled(store.isMissingKey(for: region))
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        Task { await store.remove(region) }
                    }
                } label: {
                    Label("Manage", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            case .incomplete, .notInstalled:
                Button("Download \(region.name)", systemImage: "icloud.and.arrow.down") { store.install(region) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(store.isMissingKey(for: region))
            }
        }
    }
}

private struct APIKeyView: View {
    let key: APIKeyID
    @Environment(TransitDataStore.self) private var store
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField("API Key", text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
            } footer: {
                Text(key.instructions)
            }

            Section {
                Link(destination: key.signupURL) {
                    Label("Get a \(key.name) Key", systemImage: "safari")
                }
                if store.apiKey(key) != nil {
                    Button("Remove Key", systemImage: "trash", role: .destructive) {
                        text = ""
                        store.setAPIKey(nil, for: key)
                    }
                }
            }
        }
        .navigationTitle("\(key.name) Key")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(text.trimmingCharacters(in: .whitespaces) == (store.apiKey(key) ?? ""))
            }
        }
        .onAppear { text = store.apiKey(key) ?? "" }
    }

    private func save() {
        store.setAPIKey(text, for: key)
    }
}

/// Credits each agency as its developer terms ask, with the disclaimer they share and a link to their terms.
private struct DataSourcesView: View {
    var body: some View {
        Form {
            Section {
                Text(DataSources.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(TransitRegion.allCases) { region in
                Section(region.name) {
                    ForEach(DataSources.all.filter { $0.regions.contains(region) }) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.agency)
                            Text(source.services)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(source.credit)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let terms = source.termsURL {
                                Link("Terms of Use", destination: terms)
                                    .font(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Text("Maps, place search and driving and walking directions are provided by Apple Maps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
