import Foundation

/// How a trip is doing against the time the rider has to be there.
public enum ArrivalStanding: String, Hashable, Sendable, CaseIterable {
    /// Comfortably early.
    case ahead
    /// Within five minutes either side of the target: the trip is going to plan.
    case onTime
    /// Five to ten minutes late.
    case slipping
    /// More than ten minutes late.
    case late

    public var isBehind: Bool { self == .slipping || self == .late }
}

/// A trip measured against an arrive-by time.
public struct ArriveByProgress: Hashable, Sendable {
    public var target: Date
    /// When the trip is now expected to end — or when it really did, once it has.
    public var projectedArrival: Date
    public var isFinal: Bool

    /// Positive means late.
    public var delta: TimeInterval { projectedArrival.timeIntervalSince(target) }

    public var standing: ArrivalStanding {
        switch delta {
        case ..<(-ArriveByProgress.onTimeWindow): .ahead
        case ...ArriveByProgress.onTimeWindow: .onTime
        case ...ArriveByProgress.lateWindow: .slipping
        default: .late
        }
    }

    /// Where the arrival sits on an early-to-late scale, 0…1, with the target at the middle.
    public var position: Double {
        let span = ArriveByProgress.scale
        return min(max((delta + span) / (2 * span), 0), 1)
    }

    public init(target: Date, projectedArrival: Date, isFinal: Bool = false) {
        self.target = target
        self.projectedArrival = projectedArrival
        self.isFinal = isFinal
    }

    /// Either side of the target, the trip counts as going to plan.
    public static let onTimeWindow: TimeInterval = 5 * 60
    /// Past this, being late has stopped being a detail.
    public static let lateWindow: TimeInterval = 10 * 60
    /// The bar runs from a quarter of an hour early to a quarter of an hour late.
    public static let scale: TimeInterval = 15 * 60
}

/// A time of day, as a commute remembers it: 9:00 means 9:00 whichever morning it is.
public struct TimeOfDay: Codable, Hashable, Sendable {
    /// Minutes after midnight.
    public var minutes: Int

    public init(minutes: Int) {
        self.minutes = min(max(minutes, 0), 24 * 60 - 1)
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }

    /// The next time this comes round: today if it is still to come, otherwise tomorrow.
    public func next(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
