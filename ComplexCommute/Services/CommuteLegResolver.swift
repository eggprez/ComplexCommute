import CommuteCore
import Foundation
import TransitRouting

/// Drive and walk legs come from MapKit; transit legs from the on-device router, falling back to
/// MapKit's coarse transit ETA where no installed schedule connects the two waypoints.
nonisolated struct CommuteLegResolver: LegResolving {
    let mapKit: MapKitLegResolver
    let transit: TransitPlanner

    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date) async throws -> [LegOption] {
        if mode == .transit {
            let routed = await transit.options(from: from, to: to, departingAt: departingAt)
            if !routed.isEmpty {
                return routed
            }
        }
        return try await mapKit.options(from: from, to: to, mode: mode, departingAt: departingAt)
    }
}
