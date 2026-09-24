import Foundation
import GTFSKit
import Observation
import Synchronization

/// Downloads agency schedules and tracks which feeds are installed.
///
/// Riders get a city whole: every service in it is downloaded together, and a download that fails or is
/// cancelled takes back whatever it had added, so a city is never left half there. Individual feeds are
/// still refreshed one at a time in the background as their schedules age.
@Observable
final class TransitDataStore {
    enum Activity: Equatable {
        case downloading(Double)
        case importing(Double)
        case failed(String)
    }

    enum RegionState: Equatable {
        case notInstalled
        /// Some services are missing, e.g. from before cities were downloaded whole.
        case incomplete
        case installed
    }

    private(set) var installed: [String: FeedInfo] = [:]
    private(set) var activity: [String: Activity] = [:]
    /// Why a city's last download didn't finish.
    private(set) var regionFailures: [TransitRegion: String] = [:]
    /// Bumped when keys change so views re-read the Keychain.
    private(set) var keyRevision = 0

    let library: FeedLibrary
    private var tasks: [String: Task<Void, Never>] = [:]
    private var regionTasks: [TransitRegion: Task<Void, Never>] = [:]
    /// The feeds the city download in progress is fetching, and the ones it has finished.
    private var regionPlans: [TransitRegion: (feeds: [FeedDescriptor], done: Set<String>)] = [:]

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
        await installBuiltInFeeds()
        refreshStaleFeeds()
    }

    /// The airport links the app carries go wherever the rest of their city is, and are rebuilt when the
    /// app ships a newer copy. Nothing to download, so this needs no asking.
    private func installBuiltInFeeds() async {
        for region in TransitRegion.allCases {
            let hasCity = FeedCatalog.feeds(in: region).contains { !$0.isBuiltIn && installed[$0.id] != nil }
            for feed in FeedCatalog.feeds(in: region) where feed.isBuiltIn {
                if !hasCity {
                    if installed[feed.id] != nil { await remove(feed) }
                } else if installed[feed.id]?.version != BuiltInFeeds.version,
                          let info = try? await library.install(feedID: feed.id, files: BuiltInFeeds.files(for: feed.id)) {
                    installed[feed.id] = info
                }
            }
        }
    }

    /// Quietly replaces schedules that have aged out, or that were imported before route shapes were kept.
    /// Never on cellular, and a failure just leaves the old copy in use.
    private func refreshStaleFeeds() {
        for feed in FeedCatalog.feeds where !feed.isBuiltIn {
            guard let info = installed[feed.id], !isMissingKey(for: feed),
                  Date.now.timeIntervalSince(info.importedAt) > feed.refreshInterval || !info.hasShapes else { continue }
            refresh(feed)
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

    func isMissingKey(for region: TransitRegion) -> Bool {
        FeedCatalog.feeds(in: region).contains(where: isMissingKey)
    }

    // MARK: Cities

    func state(of region: TransitRegion) -> RegionState {
        let feeds = FeedCatalog.feeds(in: region)
        let count = feeds.count { installed[$0.id] != nil }
        return count == 0 ? .notInstalled : count == feeds.count ? .installed : .incomplete
    }

    func isInstalling(_ region: TransitRegion) -> Bool {
        regionTasks[region] != nil
    }

    /// How far the city download in progress has got, weighted by each feed's size. Nil when none is running.
    func progress(of region: TransitRegion) -> Double? {
        guard let plan = regionPlans[region] else { return nil }
        let total = plan.feeds.reduce(0) { $0 + $1.downloadMB }
        guard total > 0 else { return 0 }
        let done = plan.feeds.reduce(0) { sum, feed in
            let fraction: Double = if plan.done.contains(feed.id) {
                1
            } else {
                switch activity[feed.id] {
                // Downloading and importing take roughly as long as each other.
                case .downloading(let fraction): fraction / 2
                case .importing(let fraction): 0.5 + fraction / 2
                case .failed, nil: 0
                }
            }
            return sum + feed.downloadMB * fraction
        }
        return done / total
    }

    /// The installed size of a city's schedules on this iPhone.
    func installedBytes(of region: TransitRegion) -> Int64 {
        FeedCatalog.feeds(in: region).reduce(0) { $0 + Int64(installed[$1.id]?.fileSize ?? 0) }
    }

    /// MB still to fetch: the whole city, or just what's missing from an incomplete one.
    func remainingMB(for region: TransitRegion) -> Double {
        FeedCatalog.feeds(in: region).filter { installed[$0.id] == nil }.reduce(0) { $0 + $1.downloadMB }
    }

    /// Downloads every service in the city that isn't installed yet, or all of them again with `updatingAll`.
    /// All or nothing: if any feed fails, or the rider cancels, the feeds this download added are removed again.
    func install(_ region: TransitRegion, updatingAll: Bool = false) {
        guard regionTasks[region] == nil, !isMissingKey(for: region) else { return }
        let feeds = FeedCatalog.feeds(in: region).filter { updatingAll || installed[$0.id] == nil }
        guard !feeds.isEmpty else { return }
        regionFailures[region] = nil
        regionPlans[region] = (feeds, [])
        regionTasks[region] = Task {
            defer {
                regionTasks[region] = nil
                regionPlans[region] = nil
            }
            var added: [FeedDescriptor] = []
            do {
                for feed in feeds {
                    try Task.checkCancellation()
                    // A background refresh of this feed may already be under way; let it finish first.
                    await tasks[feed.id]?.value
                    let wasInstalled = installed[feed.id] != nil
                    activity[feed.id] = .downloading(0)
                    do {
                        installed[feed.id] = try await downloadAndImport(feed, allowsCellular: true)
                        activity[feed.id] = nil
                    } catch {
                        activity[feed.id] = nil
                        throw Self.isCancellation(error) ? CancellationError() : RegionError(feed: feed, underlying: error)
                    }
                    if !wasInstalled { added.append(feed) }
                    regionPlans[region]?.done.insert(feed.id)
                }
            } catch {
                for feed in added {
                    await remove(feed)
                }
                if let error = error as? RegionError {
                    regionFailures[region] = "\(error.feed.name): \(Self.message(for: error.underlying, feed: error.feed))"
                }
            }
        }
    }

    func cancel(_ region: TransitRegion) {
        regionTasks[region]?.cancel()
    }

    func remove(_ region: TransitRegion) async {
        regionTasks[region]?.cancel()
        await regionTasks[region]?.value
        for feed in FeedCatalog.feeds(in: region) {
            tasks[feed.id]?.cancel()
            await remove(feed)
        }
        regionFailures[region] = nil
    }

    private struct RegionError: Error {
        let feed: FeedDescriptor
        let underlying: Error
    }

    // MARK: Single feeds

    /// Background refresh of one installed feed. Riders manage whole cities instead.
    private func refresh(_ feed: FeedDescriptor) {
        guard tasks[feed.id] == nil else { return }
        tasks[feed.id] = Task {
            defer {
                tasks[feed.id] = nil
                activity[feed.id] = nil
            }
            if let info = try? await downloadAndImport(feed, allowsCellular: false) {
                installed[feed.id] = info
            }
        }
    }

    private func remove(_ feed: FeedDescriptor) async {
        try? await library.remove(feedID: feed.id)
        installed[feed.id] = nil
        activity[feed.id] = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    private func downloadAndImport(_ feed: FeedDescriptor, allowsCellular: Bool) async throws -> FeedInfo {
        guard var request = feed.request(apiKey: feed.requiredKey.flatMap(apiKey)) else {
            // Carried in the app: written out and imported on the spot, a fraction of a second.
            activity[feed.id] = .importing(0)
            return try await library.install(feedID: feed.id, files: BuiltInFeeds.files(for: feed.id))
        }
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        let reporter = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                if case .downloading = self?.activity[feed.id] {
                    self?.activity[feed.id] = .downloading(fraction)
                }
            }
        }
        let (zipURL, response) = try await URLSession.shared.download(for: request, delegate: reporter)
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

    /// Forwards a download's byte progress, which the async download API otherwise keeps to itself.
    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?
        private let lastPercent = Mutex(-1)

        init(report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                guard let self else { return }
                let percent = Int(progress.fractionCompleted * 100)
                let changed = lastPercent.withLock { last in
                    defer { last = percent }
                    return last != percent
                }
                if changed { report(progress.fractionCompleted) }
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
