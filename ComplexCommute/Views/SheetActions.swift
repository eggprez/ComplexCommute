import CommuteCore
import SwiftUI
import TransitRouting

/// Requests from deep inside the sheet, or from the map behind it, for the sheet to show something.
@Observable
final class SheetRouter {
    /// A station whose departure board should open.
    var station: StationRef?
    var isShowingTransitData = false
    /// A commute (by its `widgetID`) to open with its arrival time ready to be chosen: where its widget leads.
    var commuteID: String?

    /// A tap on a widget.
    func open(_ link: AppLink) {
        switch link {
        case .commute(let id): commuteID = id
        case .station(let station): self.station = station
        }
    }
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
