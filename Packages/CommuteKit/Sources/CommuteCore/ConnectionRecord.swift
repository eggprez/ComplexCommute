import Foundation

/// How the rider came to the platform for a connection.
public enum ConnectionApproach: String, Codable, Hashable, Sendable, CaseIterable {
    case drive
    case walk
    /// Stepping off one vehicle onto the next.
    case change

    public var label: String {
        switch self {
        case .drive: "Drive"
        case .walk: "Walk"
        case .change: "Change"
        }
    }
}

/// One connection as it really went: what the plan promised, and what the day delivered.
///
/// The app plans every connection with a buffer — time in hand between reaching a platform and the
/// vehicle leaving. A record is what that buffer turned into in practice, which is what the learned
/// buffer is built from.
public struct ConnectionRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// When the connection happened.
    public var date: Date
    public var approach: ConnectionApproach
    /// `feedID:stopID` of the boarding station, where the app knows it.
    public var stationID: String?
    public var stationName: String
    public var routeName: String?
    /// When the plan in force said the rider would be on the platform.
    public var plannedArrival: Date
    /// When they really were. For a change the app cannot watch, the agency's account of it.
    public var actualArrival: Date
    /// When the vehicle was due to leave, as the plan in force had it.
    public var plannedDeparture: Date
    /// When it really left.
    public var actualDeparture: Date
    /// True when the arrival was timed from the rider — GPS, or their own word. False when it comes
    /// from the agency's realtime account of a change underground, where there is nothing to watch.
    public var isObserved: Bool
    public var wasMissed: Bool

    public init(id: UUID = UUID(), date: Date, approach: ConnectionApproach, stationID: String? = nil, stationName: String,
                routeName: String? = nil, plannedArrival: Date, actualArrival: Date, plannedDeparture: Date,
                actualDeparture: Date, isObserved: Bool, wasMissed: Bool = false) {
        self.id = id
        self.date = date
        self.approach = approach
        self.stationID = stationID
        self.stationName = stationName
        self.routeName = routeName
        self.plannedArrival = plannedArrival
        self.actualArrival = actualArrival
        self.plannedDeparture = plannedDeparture
        self.actualDeparture = actualDeparture
        self.isObserved = isObserved
        self.wasMissed = wasMissed
    }

    /// The time really in hand: from reaching the platform to the vehicle pulling out. Negative means
    /// the rider got there after it had gone.
    public var timeInHand: TimeInterval { actualDeparture.timeIntervalSince(actualArrival) }

    /// The slack the plan promised.
    public var plannedBuffer: TimeInterval { plannedDeparture.timeIntervalSince(plannedArrival) }

    /// How much of that slack the day ate. Running late eats it; a late vehicle hands it back. This is
    /// the quantity a buffer setting has to cover, so it is what the safe buffer is a percentile of.
    public var bufferUsed: TimeInterval { plannedBuffer - timeInHand }

    /// Connections at the same platform, reached the same way, are the same sort of problem: parking at
    /// a park-and-ride is nothing like a cross-platform change.
    public var groupID: String { "\(approach.rawValue)|\(stationID ?? stationName)" }
}

/// Every recorded connection of one kind at one station, and what they add up to.
public struct ConnectionGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var approach: ConnectionApproach
    public var stationID: String?
    public var stationName: String
    /// Newest first.
    public var records: [ConnectionRecord]
    public var stats: BufferStats

    public var lastUsed: Date { records.first?.date ?? .distantPast }
}

/// What a set of connections says about the buffer they need.
public struct BufferStats: Hashable, Sendable {
    public var sampleCount: Int
    public var missCount: Int
    /// Mean time in hand: the buffer the rider actually gets.
    public var averageTimeInHand: TimeInterval
    /// The worst of them.
    public var shortestTimeInHand: TimeInterval
    /// Whole minutes of buffer that would have covered `BufferLearning.safeShare` of these connections.
    public var safeBufferMinutes: Int
    /// Enough connections for the safe buffer to mean anything.
    public var isConfident: Bool { sampleCount >= BufferLearning.minimumSamples }
}

/// Turns recorded connections into the buffer they argue for.
public enum BufferLearning {
    /// Below this, a station falls back to everything learned overall.
    public static let minimumSamples = 5
    /// The share of connections the safe buffer is meant to cover.
    public static let safeShare = 0.8

    public static func stats(for records: [ConnectionRecord]) -> BufferStats? {
        guard !records.isEmpty else { return nil }
        let inHand = records.map(\.timeInHand)
        return BufferStats(
            sampleCount: records.count,
            missCount: records.count(where: \.wasMissed),
            averageTimeInHand: inHand.reduce(0, +) / Double(records.count),
            shortestTimeInHand: inHand.min() ?? 0,
            safeBufferMinutes: minutes(covering: records)
        )
    }

    /// Groups by station and approach, most recently used first.
    public static func groups(from records: [ConnectionRecord]) -> [ConnectionGroup] {
        Dictionary(grouping: records, by: \.groupID).values.compactMap { group -> ConnectionGroup? in
            let sorted = group.sorted { $0.date > $1.date }
            guard let first = sorted.first, let stats = stats(for: sorted) else { return nil }
            return ConnectionGroup(id: first.groupID, approach: first.approach, stationID: first.stationID,
                                   stationName: first.stationName, records: sorted, stats: stats)
        }
        .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// The buffer to suggest overall: one setting has to cover every connection, so they pool.
    /// Nil until there is enough history to mean anything.
    public static func suggestedBufferMinutes(from records: [ConnectionRecord]) -> Int? {
        guard records.count >= minimumSamples else { return nil }
        return minutes(covering: records)
    }

    /// Rounded up, because a buffer that is half a minute short is short.
    private static func minutes(covering records: [ConnectionRecord]) -> Int {
        let used = percentile(records.map(\.bufferUsed), safeShare)
        return max(0, Int((used / 60).rounded(.up)))
    }

    /// Nearest-rank: the smallest value with at least `share` of the sample at or below it.
    static func percentile(_ values: [TimeInterval], _ share: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((share * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
