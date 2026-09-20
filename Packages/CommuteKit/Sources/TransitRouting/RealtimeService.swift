import Foundation
import GTFSKit

/// Live data for one feed, ready to overlay on its schedule.
public struct FeedRealtime: Sendable {
    public let source: RealtimeSource
    public var tripUpdates: [RealtimeFeed.TripUpdate]
    public var alerts: [RealtimeFeed.Alert]

    public init(source: RealtimeSource, tripUpdates: [RealtimeFeed.TripUpdate] = [], alerts: [RealtimeFeed.Alert] = []) {
        self.source = source
        self.tripUpdates = tripUpdates
        self.alerts = alerts
    }
}

public struct RealtimeSnapshot: Sendable {
    public var feeds: [String: FeedRealtime] = [:]
    /// Changes whenever any underlying feed was re-fetched.
    public var version = 0
}

/// Fetches GTFS-realtime feeds on demand and keeps them briefly, so the 30-second re-plan loop and
/// several legs of one trip share a single download. Failures degrade to the schedule, never to an error.
public actor RealtimeService {
    private struct Cached {
        var feed: RealtimeFeed
        var fetchedAt: Date
    }

    private let apiKey: @Sendable (APIKeyID) -> String?
    private let session: URLSession
    private var cache: [URL: Cached] = [:]
    private var version = 0

    /// A feed that stopped updating is still better than nothing for a few minutes, then it misleads.
    static let staleAfter: TimeInterval = 300

    public init(apiKey: @escaping @Sendable (APIKeyID) -> String?) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func snapshot(for feedIDs: [String]) async -> RealtimeSnapshot {
        let descriptors = feedIDs.compactMap(FeedCatalog.feed(id:)).filter { $0.realtime != nil }

        // Several schedules can share one realtime URL (every MTA bus feed does); fetch each URL once.
        var requests: [URL: (request: URLRequest, maxAge: TimeInterval)] = [:]
        for descriptor in descriptors {
            guard let source = descriptor.realtime else { continue }
            let key = descriptor.requiredKey.flatMap(apiKey)
            if descriptor.requiredKey != nil, key == nil { continue }
            for url in source.tripUpdateURLs + source.alertURLs {
                requests[url] = (descriptor.request(for: url, apiKey: key), source.maxAge)
            }
        }
        let due = requests.filter { url, entry in
            cache[url].map { Date.now.timeIntervalSince($0.fetchedAt) >= entry.maxAge } ?? true
        }

        if !due.isEmpty {
            let session = session
            let fetched = await withTaskGroup(of: (URL, RealtimeFeed?).self) { group in
                for (url, entry) in due {
                    group.addTask {
                        guard let (data, response) = try? await session.data(for: entry.request),
                              (response as? HTTPURLResponse)?.statusCode == 200 else { return (url, nil) }
                        return (url, try? RealtimeFeed(data: data))
                    }
                }
                var results: [URL: RealtimeFeed] = [:]
                for await (url, feed) in group {
                    results[url] = feed
                }
                return results
            }
            for (url, feed) in fetched {
                cache[url] = Cached(feed: feed, fetchedAt: .now)
            }
            if !fetched.isEmpty { version += 1 }
        }

        var snapshot = RealtimeSnapshot(version: version)
        for descriptor in descriptors {
            guard let source = descriptor.realtime else { continue }
            func fresh(_ urls: [URL]) -> [RealtimeFeed] {
                urls.compactMap { cache[$0] }.filter { Date.now.timeIntervalSince($0.fetchedAt) < Self.staleAfter }.map(\.feed)
            }
            snapshot.feeds[descriptor.id] = FeedRealtime(
                source: source,
                tripUpdates: fresh(source.tripUpdateURLs).flatMap(\.tripUpdates),
                alerts: fresh(source.alertURLs + source.tripUpdateURLs).flatMap(\.alerts)
            )
        }
        return snapshot
    }
}
