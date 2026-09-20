import SwiftData
import SwiftUI

@main
struct ComplexCommuteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Commute.self, SavedPlace.self])
    }
}
