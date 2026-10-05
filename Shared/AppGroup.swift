import Foundation

/// What the app and its widgets hold in common. A widget runs in a process of its own and sees nothing of the
/// app's files but this.
nonisolated enum AppGroup {
    static let id = "group.scottai.commuter-app"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }

    /// Where the app kept schedules before widgets read them too.
    static var legacyFeedsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Feeds", directoryHint: .isDirectory)
    }

    /// The installed schedules. In the shared container, so the departures widget can read them; a build without
    /// the entitlement keeps them where they always were.
    static var feedsDirectory: URL {
        container?.appending(path: "Feeds", directoryHint: .isDirectory) ?? legacyFeedsDirectory
    }
}

nonisolated enum WidgetKind {
    static let commute = "CommuteShortcut"
    static let nearby = "NearbyDepartures"
}

/// Where the rider last was, as far as either the app or a widget could tell: what the departures widget falls
/// back on when it isn't given a fix of its own. Kept on the device, and only the latest.
nonisolated struct LastKnownPlace: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var date: Date

    private static let key = "lastKnownPlace"

    static func load() -> LastKnownPlace? {
        AppGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LastKnownPlace.self, from: $0) }
    }

    func save() {
        AppGroup.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
