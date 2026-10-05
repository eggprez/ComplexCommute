import AppIntents
import CommuteCore
import CoreLocation
import GTFSKit
import TransitRouting
import WidgetKit

// MARK: Configuration

enum NearbyModeChoice: String, AppEnum {
    case all
    case rail
    case bus

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    static let caseDisplayRepresentations: [NearbyModeChoice: DisplayRepresentation] = [
        .all: "Everything",
        .rail: "Subway & Rail",
        .bus: "Buses",
    ]

    nonisolated var modes: NearbyModes {
        switch self {
        case .all: .all
        case .rail: .rail
        case .bus: .bus
        }
    }
}

struct NearbyDeparturesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Nearby Departures"
    static let description = IntentDescription("Choose which services the widget lists.")

    @Parameter(title: "Show", default: .all)
    var show: NearbyModeChoice
}

/// The widget's refresh button: find the rider again, then look the departures up again. Without it the widget
/// still keeps itself current, but only looks for the rider as often as iOS lets it reload.
nonisolated struct RefreshDeparturesIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Departures"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        NearbyRefresh.request()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nearby)
        return .result()
    }
}

/// A note from the refresh button to the next reload, which may run in a fresh process.
nonisolated enum NearbyRefresh {
    private static let key = "nearby.wantsFreshFix"

    static func request() {
        AppGroup.defaults.set(true, forKey: key)
    }

    static func take() -> Bool {
        defer { AppGroup.defaults.removeObject(forKey: key) }
        return AppGroup.defaults.bool(forKey: key)
    }
}

// MARK: Timeline

nonisolated struct NearbyEntry: TimelineEntry {
    enum Content {
        case boards([NearbyBoard])
        /// Location is off for the widget and the app has never said where the rider was.
        case noLocation
        /// No schedules have been downloaded.
        case noSchedules
        case nothingNearby
    }

    let date: Date
    var content: Content
    /// When the departures were looked up: what "Updated" says, and how long live times are trusted.
    var fetchedAt: Date

    /// A prediction is good for a few minutes. Past that the time still stands, but not as a promise.
    var showsLive: Bool { date.timeIntervalSince(fetchedAt) < NearbyTimelineProvider.liveFor }
}

nonisolated struct NearbyTimelineProvider: AppIntentTimelineProvider {
    /// Battery against freshness. A minute-by-minute timeline costs nothing once it is built, so the countdowns
    /// always tick; what costs is building it, which takes a location fix, a read of the schedules and, where an
    /// agency publishes them, a download of live times. iOS allows a widget a few dozen of those a day.
    static let reloadWithLiveTimes: TimeInterval = 15 * 60
    static let reloadFromSchedule: TimeInterval = 30 * 60
    /// The timeline runs well past the next reload, in case iOS is slow to grant it.
    static let minutesAhead = 75
    static let horizon: TimeInterval = 2 * 3_600
    static let liveFor: TimeInterval = 10 * 60
    /// A fix this recent is as good as a new one for picking the nearest stations.
    static let fixMaxAge: TimeInterval = 3 * 60

    func placeholder(in context: Context) -> NearbyEntry {
        NearbyEntry(date: .now, content: .boards(NearbyBoard.samples(at: .now)), fetchedAt: .now)
    }

    func snapshot(for configuration: NearbyDeparturesIntent, in context: Context) async -> NearbyEntry {
        // The gallery wants something at once, and something that shows what the widget is for.
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration, fresh: false).entry(at: .now)
    }

    func timeline(for configuration: NearbyDeparturesIntent, in context: Context) async -> Timeline<NearbyEntry> {
        let loaded = await load(configuration, fresh: NearbyRefresh.take())
        let now = Date.now
        guard case .boards(let boards) = loaded.content else {
            return Timeline(entries: [loaded.entry(at: now)], policy: .after(now.addingTimeInterval(Self.reloadFromSchedule)))
        }
        // One entry a minute, on the minute, so "4 min" turns to "3 min" when it should.
        let firstMinute = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let entries = [loaded.entry(at: now)] + (1...Self.minutesAhead).map { loaded.entry(at: firstMinute.addingTimeInterval(TimeInterval($0) * 60)) }
        let isLive = boards.contains { $0.groups.contains { $0.departures.contains(where: \.isRealtime) } }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(isLive ? Self.reloadWithLiveTimes : Self.reloadFromSchedule)))
    }

    private struct Loaded {
        var content: NearbyEntry.Content
        var fetchedAt: Date

        func entry(at date: Date) -> NearbyEntry {
            NearbyEntry(date: date, content: content, fetchedAt: fetchedAt)
        }
    }

    private func load(_ configuration: NearbyDeparturesIntent, fresh: Bool) async -> Loaded {
        let now = Date.now
        guard let place = await WidgetLocator.shared.place(fresh: fresh) else {
            return Loaded(content: .noLocation, fetchedAt: now)
        }
        // Read-only: the schedules are the app's to manage.
        let library = FeedLibrary(directory: AppGroup.feedsDirectory, isReadOnly: true)
        let realtime = RealtimeService { KeychainStore.string(for: $0.rawValue) }
        let planner = TransitPlanner(library: library, realtime: realtime)
        let boards = await planner.nearbyBoards(around: Coordinate(latitude: place.latitude, longitude: place.longitude), at: now,
                                                modes: configuration.show.modes, horizon: Self.horizon)
        if boards.isEmpty {
            return Loaded(content: await library.installedFeeds().isEmpty ? .noSchedules : .nothingNearby, fetchedAt: now)
        }
        return Loaded(content: .boards(boards), fetchedAt: now)
    }
}

// MARK: Location

/// Where the rider is, as cheaply as will do. A reload on the widget's own schedule takes whatever fix the phone
/// already has; only the refresh button spends the power to get a new one.
@MainActor
final class WidgetLocator: NSObject, CLLocationManagerDelegate {
    static let shared = WidgetLocator()

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    override private init() {
        super.init()
        manager.delegate = self
    }

    func place(fresh: Bool) async -> LastKnownPlace? {
        guard manager.isAuthorizedForWidgetUpdates else {
            // The app notes where the rider was whenever it is used; better than a blank widget.
            return LastKnownPlace.load()
        }
        var location = manager.location
        let isRecent = location.map { -$0.timestamp.timeIntervalSinceNow < NearbyTimelineProvider.fixMaxAge } ?? false
        if fresh || !isRecent {
            // Stations are hundreds of metres apart; only being asked outright is worth the GPS.
            manager.desiredAccuracy = fresh ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
            location = await request() ?? location
        }
        guard let location else { return LastKnownPlace.load() }
        let place = LastKnownPlace(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, date: location.timestamp)
        place.save()
        return place
    }

    /// One fix, or nil if none comes in the time a widget reload can spare.
    private func request() async -> CLLocation? {
        guard waiting == nil else { return nil }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            finish(nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in finish(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in finish(nil) }
    }
}

// MARK: Sample

extension NearbyBoard {
    /// What the widget gallery shows, and what stands in while the first real board loads.
    nonisolated static func samples(at now: Date) -> [NearbyBoard] {
        func group(_ name: String, _ color: String, _ text: String, type: Int, to destination: String, in minutes: [Int], live: Bool = true) -> DepartureGroup {
            let route = RouteBadge(name: name, colorHex: color, textColorHex: text, type: type)
            return DepartureGroup(route: route, destination: destination, departures: minutes.map {
                let time = now.addingTimeInterval(TimeInterval($0) * 60 + 30)
                return StopDeparture(route: route, destination: destination, scheduled: time, time: time, isRealtime: live)
            })
        }
        let here = Coordinate(latitude: 40.7193, longitude: -74.0007)
        return [
            NearbyBoard(station: StationRef(feedID: "sample", stopID: "canal", name: "Canal St", coordinate: here), meters: 160, isBus: false, groups: [
                group("Q", "FCCC0A", "000000", type: 1, to: "96 St", in: [2, 9, 17]),
                group("6", "00933C", "FFFFFF", type: 1, to: "Pelham Bay Park", in: [4, 10, 15]),
                group("N", "FCCC0A", "000000", type: 1, to: "Astoria-Ditmars Blvd", in: [6, 14, 22]),
                group("J", "996633", "FFFFFF", type: 1, to: "Jamaica Center", in: [7, 19, 31], live: false),
            ]),
            NearbyBoard(station: StationRef(feedID: "sample", stopID: "bway", name: "Broadway & Howard St", coordinate: here), meters: 90, isBus: true, groups: [
                group("M55", "00AEEF", "FFFFFF", type: 3, to: "South Ferry", in: [3, 15, 27]),
            ]),
            NearbyBoard(station: StationRef(feedID: "sample", stopID: "chambers", name: "Chambers St", coordinate: here), meters: 520, isBus: false, groups: [
                group("A", "0039A6", "FFFFFF", type: 1, to: "Inwood-207 St", in: [5, 11, 18]),
                group("1", "EE352E", "FFFFFF", type: 1, to: "Van Cortlandt Park", in: [3, 8, 13]),
            ]),
            NearbyBoard(station: StationRef(feedID: "sample", stopID: "church", name: "Church St & Lispenard St", coordinate: here), meters: 240, isBus: true, groups: [
                group("M20", "00AEEF", "FFFFFF", type: 3, to: "Lincoln Center", in: [8, 24], live: false),
            ]),
        ]
    }
}
