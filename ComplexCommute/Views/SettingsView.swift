import GTFSKit
import SwiftUI

struct SettingsView: View {
    @Environment(TransitDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(TransitRegion.allCases) { region in
                    Section {
                        ForEach(FeedCatalog.feeds(in: region)) { feed in
                            FeedRow(feed: feed)
                        }
                    } header: {
                        Text(region.name)
                    } footer: {
                        if region == TransitRegion.allCases.last {
                            Text("Schedules are stored on this iPhone so routes can be planned without a server. Installed schedules take several times their download size.")
                        }
                    }
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

private struct FeedRow: View {
    let feed: FeedDescriptor
    @Environment(TransitDataStore.self) private var store

    var body: some View {
        let info = store.installed[feed.id]
        let activity = store.activity[feed.id]

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.name)
                status(info: info, activity: activity)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory(info: info, activity: activity)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(info: FeedInfo?, activity: TransitDataStore.Activity?) -> some View {
        switch activity {
        case .downloading:
            Text("Downloading…")
        case .importing(let fraction):
            ProgressView(value: fraction) {
                Text("Importing… \(fraction, format: .percent.precision(.fractionLength(0)))")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        case nil:
            if let info {
                Text("\(info.stopCount) stops · \(Int64(info.fileSize), format: .byteCount(style: .file)) · Updated \(info.importedAt, format: .dateTime.month().day())")
            } else if let key = feed.requiredKey, store.isMissingKey(for: feed) {
                Text("Requires a \(key.name) API key")
            } else if let size = feed.downloadMB {
                Text("\(feed.detail) · \(size, format: .number.precision(.fractionLength(0...1))) MB download")
            } else {
                Text(feed.detail)
            }
        }
    }

    @ViewBuilder
    private func accessory(info: FeedInfo?, activity: TransitDataStore.Activity?) -> some View {
        switch activity {
        case .downloading, .importing:
            Button("Cancel", systemImage: "stop.circle") { store.cancel(feed) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        case .failed, nil:
            if info != nil {
                Menu("Manage", systemImage: "checkmark.circle.fill") {
                    Button("Update Now", systemImage: "arrow.down.circle") { store.install(feed) }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        Task { await store.remove(feed) }
                    }
                }
                .labelStyle(.iconOnly)
                .tint(.green)
            } else {
                Button("Download", systemImage: "icloud.and.arrow.down") { store.install(feed) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(store.isMissingKey(for: feed))
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
