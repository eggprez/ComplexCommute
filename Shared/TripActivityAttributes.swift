import ActivityKit
import AppIntents
import CommuteCore

/// The Live Activity for a trip in progress. Everything that changes is in the glance; the app
/// writes it and the widget extension draws it.
nonisolated struct TripActivityAttributes: ActivityAttributes {
    typealias ContentState = TripGlance

    var destination: String
}

/// A Live Activity button: tells the trip what happened without opening the app. Runs in the app's process,
/// which iOS launches in the background if it has to.
struct TripActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Update Trip"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(_ action: TripAction) {
        self.action = action.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let action = TripAction(rawValue: action) {
            TripActionRouter.handler?(action)
        }
        return .result()
    }
}

/// A Live Activity button for one of the ways onward from the next boarding: picks it without opening the app.
struct ChooseBranchIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Choose Route"
    static let isDiscoverable = false

    @Parameter(title: "Branch")
    var branch: String

    init() {}

    init(_ branch: String) {
        self.branch = branch
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        TripActionRouter.branchHandler?(branch)
        return .result()
    }
}

/// Where Live Activity buttons go. Set by the app; the widget extension only draws the buttons.
@MainActor
enum TripActionRouter {
    static var handler: ((TripAction) -> Void)?
    static var branchHandler: ((String) -> Void)?
}
