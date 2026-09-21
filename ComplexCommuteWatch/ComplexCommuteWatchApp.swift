import SwiftUI

@main
struct ComplexCommuteWatchApp: App {
    @State private var phone = PhoneLink()

    var body: some Scene {
        WindowGroup {
            WatchRootView(phone: phone)
                .task { phone.activate() }
        }
    }
}

/// The trip when there is one; otherwise the commutes that could become one.
struct WatchRootView: View {
    let phone: PhoneLink

    var body: some View {
        NavigationStack {
            if let trip = phone.context.trip {
                WatchTripView(trip: trip, phone: phone)
            } else {
                CommuteListView(phone: phone)
            }
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { phone.error != nil }, set: { if !$0 { phone.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(phone.error ?? "")
        }
    }
}
