import CommuteCore
import SwiftUI
import TransitRouting

/// Requests from deep inside the sheet, or from the map behind it, for the sheet to show something.
@Observable
final class SheetRouter {
    /// A station whose departure board should open.
    var station: StationRef?
    var isShowingTransitData = false
}

extension EnvironmentValues {
    @Entry var transitPlanner: TransitPlanner?
}

extension Waypoint {
    /// The station behind a waypoint picked from an installed schedule.
    var station: StationRef? {
        guard case .stop(let feedID, let stopID) = kind else { return nil }
        return StationRef(feedID: feedID, stopID: stopID, name: name, coordinate: coordinate)
    }
}
