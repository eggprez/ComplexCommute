import ActivityKit
import CommuteCore

/// The Live Activity for a trip in progress. Everything that changes is in the glance; the app
/// writes it and the widget extension draws it.
nonisolated struct TripActivityAttributes: ActivityAttributes {
    typealias ContentState = TripGlance

    var destination: String
}
