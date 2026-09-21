import SwiftData
import SwiftUI

@main
struct ComplexCommuteApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
        }
        .modelContainer(services.container)
        // Woken to keep a trip in progress, or a commute that is coming up, honest about its times.
        .backgroundTask(.appRefresh(AppServices.refreshIdentifier)) {
            await services.refreshInBackground()
        }
    }
}
