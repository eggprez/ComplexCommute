import SwiftUI
import TransitRouting

/// Full-screen map with an always-present bottom sheet, like Maps.
struct RootView: View {
    static let collapsed = PresentationDetent.height(88)
    static let half = PresentationDetent.fraction(0.45)

    @State private var location: LocationService
    @State private var planner: TripPlannerModel
    @State private var transitData: TransitDataStore
    @State private var detent = RootView.half

    init() {
        let location = LocationService()
        let transitData = TransitDataStore()
        let realtime = RealtimeService { KeychainStore.string(for: $0.rawValue) }
        let resolver = CommuteLegResolver(mapKit: MapKitLegResolver(), transit: TransitPlanner(library: transitData.library, realtime: realtime))
        _location = State(initialValue: location)
        _transitData = State(initialValue: transitData)
        _planner = State(initialValue: TripPlannerModel(location: location, resolver: resolver))
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
