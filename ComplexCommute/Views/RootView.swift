import SwiftUI

/// Full-screen map with an always-present bottom sheet, like Maps.
struct RootView: View {
    static let collapsed = PresentationDetent.height(88)
    static let half = PresentationDetent.fraction(0.45)

    @State private var location: LocationService
    @State private var planner: TripPlannerModel
    @State private var detent = RootView.half
    @State private var transitData = TransitDataStore()

    init() {
        let location = LocationService()
        _location = State(initialValue: location)
        _planner = State(initialValue: TripPlannerModel(location: location))
    }

    var body: some View {
        TripMapView(planner: planner, sheetIsCollapsed: detent == Self.collapsed)
            .sheet(isPresented: .constant(true)) {
                HomeSheetView(planner: planner, detent: $detent)
                    .presentationDetents([Self.collapsed, Self.half, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: Self.half))
                    .interactiveDismissDisabled()
                    .environment(transitData)
            }
            .task { location.start() }
            .task { await transitData.load() }
    }
}
