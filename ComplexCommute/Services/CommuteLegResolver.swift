import CommuteCore
import Foundation
import TransitRouting

/// Drive and walk legs come from MapKit; transit legs from the on-device router, falling back to
/// MapKit's coarse transit ETA where no installed schedule connects the two waypoints.
nonisolated struct CommuteLegResolver: LegResolving {
    let mapKit: MapKitLegResolver
    let transit: TransitPlanner

    func options(from: Waypoint, to: Waypoint, mode: TravelMode, departingAt: Date, isWaitingAtOrigin: Bool) async throws -> [LegOption] {
        if mode == .transit {
            let routed = await transit.options(from: from, to: to, departingAt: departingAt, bufferSeconds: StationBuffer.seconds,
                                               isWaitingAtOrigin: isWaitingAtOrigin)
            if !routed.isEmpty {
                return routed
            }
        }
        return try await mapKit.options(from: from, to: to, mode: mode, departingAt: departingAt)
    }
}

/// Time the rider wants in hand when reaching a station and at every change of trains. Set in Settings.
nonisolated enum StationBuffer {
    static let key = "stationBufferMinutes"
    static let defaultMinutes = TransitPlanner.defaultBufferSeconds / 60
    static let range = 0...15

    static var seconds: Int {
        let minutes = UserDefaults.standard.object(forKey: key) as? Int ?? defaultMinutes
        return min(max(minutes, range.lowerBound), range.upperBound) * 60
    }
}
