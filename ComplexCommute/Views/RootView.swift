import SwiftUI
import TransitRouting

/// Full-screen map with an always-present bottom sheet, like Maps.
struct RootView: View {
    static let collapsed = PresentationDetent.height(88)
    /// Room for the Arrive By bar above the trip's stats, so pulling the sheet down still shows both.
    static let collapsedWithTarget = PresentationDetent.height(148)
    static let half = PresentationDetent.fraction(0.45)

    /// The smallest the sheet goes, which depends on whether there is an arrival time to show.
    static func collapsed(withTarget: Bool) -> PresentationDetent {
        withTarget ? collapsedWithTarget : collapsed
    }

    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase
    @State private var detent = RootView.half
    @State private var router = SheetRouter()

    private var planner: TripPlannerModel { services.planner }
    private var hasTarget: Bool { planner.active?.arriveBy != nil }
    private var isCollapsed: Bool { detent == Self.collapsed || detent == Self.collapsedWithTarget }
    private var location: LocationService { services.location }
    private var transitData: TransitDataStore { services.transitData }
    private var transit: TransitPlanner { services.transit }

    var body: some View {
        TripMapView(planner: planner, sheetIsCollapsed: isCollapsed, router: router)
            .sheet(isPresented: .constant(true)) {
                HomeSheetView(planner: planner, detent: $detent)
                    .presentationDetents([Self.collapsed(withTarget: hasTarget), Self.half, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: Self.half))
                    .interactiveDismissDisabled()
                    .environment(transitData)
                    .environment(router)
                    .environment(services.notifier)
                    .environment(\.transitPlanner, transit)
            }
            .task { location.start() }
            .task { await transitData.load() }
            .task { await services.notifier.refresh() }
            .onAppear { services.scheduleBackgroundRefresh() }
            // Notifications can be turned off in iOS Settings while the app is away.
            // Setting or dropping an arrival time changes how small the sheet can go.
            .onChange(of: hasTarget) { _, nowHasTarget in
                if isCollapsed { detent = Self.collapsed(withTarget: nowHasTarget) }
            }
            .onChange(of: scenePhase, initial: true) {
                services.sceneDidChange(isActive: scenePhase == .active)
                guard scenePhase == .active else { return }
                Task { await services.notifier.refresh() }
            }
    }
}
