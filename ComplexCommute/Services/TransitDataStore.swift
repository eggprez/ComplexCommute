import Foundation
import GTFSKit
import Observation
import Synchronization

/// Downloads agency schedules and tracks which feeds are installed.
@Observable
final class TransitDataStore {
    enum Activity: Equatable {
        case downloading
        case importing(Double)
        case failed(String)
    }

    private(set) var installed: [String: FeedInfo] = [:]
    private(set) var activity: [String: Activity] = [:]
    /// Bumped when keys change so views re-read the Keychain.
    private(set) var keyRevision = 0

    let library: FeedLibrary
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        var directory = URL.applicationSupportDirectory.appending(path: "Feeds", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Schedules can always be downloaded again; keep them out of iCloud/device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        library = FeedLibrary(directory: directory)
    }

    var hasInstalledFeeds: Bool { !installed.isEmpty }

    func load() async {
        installed = Dictionary(uniqueKeysWithValues: await library.installedFeeds().map { ($0.feedID, $0) })
        refreshStaleFeeds()
    }

    /// Quietly replaces schedules that have aged out. Never on cellular, and a failure just leaves the old copy in use.
    private func refreshStaleFeeds() {
        for feed in FeedCatalog.feeds {
            guard let info = installed[feed.id], Date.now.timeIntervalSince(info.importedAt) > feed.refreshInterval,
                  !isMissingKey(for: feed) else { continue }
            install(feed, isAutomatic: true)
        }
    }

    // MARK: API keys

    func apiKey(_ id: APIKeyID) -> String? {
        _ = keyRevision
        return KeychainStore.string(for: id.rawValue)
    }

    func setAPIKey(_ value: String?, for id: APIKeyID) {
        KeychainStore.set(value?.trimmingCharacters(in: .whitespacesAndNewlines), for: id.rawValue)
        keyRevision += 1
    }

    func isMissingKey(for feed: FeedDescriptor) -> Bool {
        feed.requiredKey.map { apiKey($0) == nil } ?? false
    }

    // MARK: Install / remove

    func install(_ feed: FeedDescriptor, isAutomatic: Bool = false) {
        guard tasks[feed.id] == nil else { return }
        activity[feed.id] = .downloading
        tasks[feed.id] = Task {
            defer { tasks[feed.id] = nil }
            do {
                installed[feed.id] = try await downloadAndImport(feed, allowsCellular: !isAutomatic)
                activity[feed.id] = nil
            } catch is CancellationError {
                activity[feed.id] = nil
            } catch let error as URLError where error.code == .cancelled {
                activity[feed.id] = nil
            } catch {
                activity[feed.id] = isAutomatic ? nil : .failed(Self.message(for: error, feed: feed))
            }
        }
    }

    func cancel(_ feed: FeedDescriptor) {
        tasks[feed.id]?.cancel()
    }

    func remove(_ feed: FeedDescriptor) async {
        try? await library.remove(feedID: feed.id)
        installed[feed.id] = nil
        activity[feed.id] = nil
    }

    private func downloadAndImport(_ feed: FeedDescriptor, allowsCellular: Bool) async throws -> FeedInfo {
        var request = feed.request(apiKey: feed.requiredKey.flatMap(apiKey))
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        let (zipURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: zipURL) }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw DownloadError.httpStatus(status)
        }

        activity[feed.id] = .importing(0)
        // The importer reports per chunk from a background thread; only forward whole-percent changes.
        let lastPercent = Mutex(-1)
        return try await library.install(feedID: feed.id, zip: zipURL) { [weak self] progress in
            let percent = Int(progress.fraction * 100)
            let changed = lastPercent.withLock { last in
                defer { last = percent }
                return last != percent
            }
            guard changed else { return }
            Task { @MainActor in
                if case .importing = self?.activity[feed.id] {
                    self?.activity[feed.id] = .importing(progress.fraction)
                }
            }
        }
    }

    private enum DownloadError: Error {
        case httpStatus(Int)
    }

    private static func message(for error: Error, feed: FeedDescriptor) -> String {
        switch error {
        case DownloadError.httpStatus(let status) where status == 401 || status == 403:
            "\(feed.requiredKey?.name ?? "The agency") rejected the API key."
        case DownloadError.httpStatus(let status):
            "The server responded with an error (\(status))."
        case is ZipError, is GTFSImportError:
            "The downloaded schedule couldn't be read."
        default:
            error.localizedDescription
        }
    }
}
