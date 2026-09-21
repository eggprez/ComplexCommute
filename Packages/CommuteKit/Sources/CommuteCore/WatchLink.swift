import Foundation

// What the phone and the Watch say to each other. The phone does all the planning; the Watch shows
// the trip and passes on what the rider tells it.

/// A leg or ride still to come, as one line of a list.
public struct UpcomingStep: Codable, Hashable, Sendable {
    public var mode: TravelMode
    public var route: RouteLabel?
    public var title: String
    public var time: Date

    public init(mode: TravelMode, route: RouteLabel? = nil, title: String, time: Date) {
        self.mode = mode
        self.route = route
        self.title = title
        self.time = time
    }
}

/// A plan that gets there sooner, offered for the rider to switch to.
public struct FasterOffer: Codable, Hashable, Sendable {
    public var arrival: Date
    public var saving: TimeInterval
    public var routes: [RouteLabel]
}

public struct WatchTripState: Codable, Hashable, Sendable {
    public var glance: TripGlance
    public var upcoming: [UpcomingStep]
    /// The place "I'm at…" would say the rider has reached, while there is one.
    public var nextWaypoint: String?
    public var canMarkMissed: Bool
    public var faster: FasterOffer?
    /// The plan was replaced under the rider; how much later (or, negative, sooner) they now arrive.
    public var planChange: TimeInterval?
    /// The phone could not keep itself running for this trip, so what the Watch shows will age
    /// until the app is opened there.
    public var needsPhone = false
}

/// A saved commute, as the Watch lists it.
public struct WatchCommute: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var arriveBy: Date?
    /// "Home → Metropark → Office"
    public var summary: String

    public init(id: String, name: String, arriveBy: Date?, summary: String) {
        self.id = id
        self.name = name
        self.arriveBy = arriveBy
        self.summary = summary
    }
}

/// Everything the Watch shows. Sent whole each time: the latest one is the only one that matters.
public struct WatchContext: Codable, Hashable, Sendable {
    public var trip: WatchTripState?
    public var commutes: [WatchCommute]
    public var sentAt: Date

    public init(trip: WatchTripState? = nil, commutes: [WatchCommute] = [], sentAt: Date = .now) {
        self.trip = trip
        self.commutes = commutes
        self.sentAt = sentAt
    }
}

public enum WatchCommand: Codable, Hashable, Sendable {
    case refresh
    case start(commuteID: String)
    case markArrived
    case markMissed
    case followFaster
    case dismissNotice
    case endTrip
}

/// Every command is answered with how things stand afterwards, and what went wrong if something did.
public struct WatchReply: Codable, Sendable {
    public var context: WatchContext
    public var error: String?

    public init(context: WatchContext, error: String? = nil) {
        self.context = context
        self.error = error
    }
}

public enum WatchLink {
    /// The key both sides file their encoded payload under.
    public static let payloadKey = "payload"
}

extension ActiveTrip {
    public func watchState(at now: Date) -> WatchTripState {
        var steps: [UpcomingStep] = []
        for (offset, leg) in remainingLegs.enumerated() {
            if leg.option.rides.isEmpty {
                if offset > 0 {
                    steps.append(UpcomingStep(mode: leg.mode, title: "\(leg.mode.verb) to \(leg.to.name)", time: leg.departure))
                }
                continue
            }
            let current = offset == 0 ? currentRide(at: now) : nil
            for ride in leg.option.rides where ride != current && (offset > 0 || ride.board > now) {
                steps.append(UpcomingStep(mode: .transit, route: ride.label, title: "\(ride.boardStopName) → \(ride.alightStopName)", time: ride.board))
            }
        }

        var state = WatchTripState(glance: glance(at: now), upcoming: steps, nextWaypoint: currentLeg?.to.name,
                                   canMarkMissed: currentLeg.map { $0.mode == .transit && hasBoarded && !$0.option.rides.isEmpty } ?? false)
        switch notice {
        case .fasterOption(let itinerary):
            state.faster = FasterOffer(arrival: itinerary.arrival, saving: arrival.timeIntervalSince(itinerary.arrival),
                                       routes: itinerary.legs.flatMap(\.option.rides).map(\.label))
        case .planChanged(let previousArrival):
            state.planChange = arrival.timeIntervalSince(previousArrival)
        case nil:
            break
        }
        return state
    }
}
