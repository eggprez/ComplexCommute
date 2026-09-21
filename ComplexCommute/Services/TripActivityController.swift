import ActivityKit
import CommuteCore
import Foundation

/// Keeps the Live Activity saying what the trip says. Updates are handed over one at a time, newest
/// wins: ActivityKit's calls are async, and two of them racing could leave the older one on screen.
final class TripActivityController {
    /// The last glance handed over, shown or not: a start that was refused isn't retried on every fix.
    private var offered: TripGlance?
    private var lastOffer = Date.distantPast
    /// The trip ended and its activity was closed; don't open another for the same trip.
    private var hasEnded = false
    private let glances: AsyncStream<TripGlance?>.Continuation

    /// With nothing new to say, the activity is still told so this often, or it would mark itself stale.
    nonisolated static let keepAlive: TimeInterval = 2 * 60
    /// How long without a word from the app before the activity admits it may be out of date.
    nonisolated static let staleAfter: TimeInterval = 5 * 60
    /// A finished trip's verdict stays on the Lock Screen this long.
    nonisolated static let lingerAfterArrival: TimeInterval = 10 * 60

    init() {
        let (stream, continuation) = AsyncStream<TripGlance?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        glances = continuation
        Task { [weak self] in
            for await glance in stream {
                await self?.apply(glance)
            }
        }
    }

    /// Shows this glance, or takes the activity down when there is no trip.
    /// - Parameter force: try again even if nothing changed, as when the app comes to the front
    ///   and can finally start an activity that a background start was refused.
    func show(_ glance: TripGlance?, force: Bool = false) {
        let isDue = glance != nil && Date.now.timeIntervalSince(lastOffer) >= Self.keepAlive
        guard force || isDue || glance != offered else { return }
        offered = glance
        lastOffer = .now
        glances.yield(glance)
    }

    private func apply(_ glance: TripGlance?) async {
        guard let glance else {
            await Self.endAll()
            hasEnded = false
            return
        }
        guard !hasEnded else { return }
        hasEnded = await Self.push(glance)
    }

    // An Activity isn't Sendable, so it can't be held here on the main actor and awaited on: these
    // look it up and use it without it ever belonging to anyone.

    @concurrent
    private nonisolated static func endAll() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// - Returns: true if this was the trip's last word and the activity is now closed.
    @concurrent
    private nonisolated static func push(_ glance: TripGlance) async -> Bool {
        let content = ActivityContent(state: glance, staleDate: glance.isFinished ? nil : .now + staleAfter)
        // One left over from before the app was closed mid-trip is this trip's, and is carried on with.
        var current = Activity<TripActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        if current == nil {
            guard !glance.isFinished, ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
            // Refused when the app isn't in front (a trip started from the Watch); `show` tries again.
            current = try? Activity.request(attributes: TripActivityAttributes(destination: glance.destination), content: content)
        }
        guard let current else { return false }

        if glance.isFinished {
            await current.end(content, dismissalPolicy: .after(.now + lingerAfterArrival))
            return true
        }
        await current.update(content)
        return false
    }
}
