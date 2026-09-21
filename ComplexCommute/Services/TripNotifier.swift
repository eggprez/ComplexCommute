import CommuteCore
import Foundation
import Observation
import UserNotifications

/// Local notifications for a trip: when to leave, and when a better plan has turned up.
///
/// Nothing is presented while the app is in front — the trip screen is already saying it — so these
/// only ever surface when the phone is away.
@Observable
final class TripNotifier {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The alternative last notified about, so one faster train isn't announced over and over.
    private var announced: Itinerary.ID?

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let leaveNow = "leave-now"
        static let fasterOption = "faster-option"
        static let needsPhone = "needs-phone"
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }

    func refresh() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asked the first time the rider sets off, and again if they later ask for a standing reminder.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refresh()
        guard authorization == .notDetermined else { return isAuthorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refresh()
        return granted
    }

    /// A plan that gets there meaningfully sooner. Announced once per alternative.
    func announceFasterOption(_ itinerary: Itinerary, saving: TimeInterval) {
        guard isAuthorized, announced != itinerary.id else { return }
        announced = itinerary.id

        let content = UNMutableNotificationContent()
        content.title = "Faster Way to Go"
        let routes = itinerary.legs.flatMap(\.option.rides).map(\.routeName).joined(separator: " → ")
        content.body = "\(Int(saving / 60)) min sooner if you switch\(routes.isEmpty ? "" : " to \(routes)"). Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: ID.fasterOption, content: content, trigger: nil))
    }

    /// A trip started from the Watch with the app closed: iOS only lets the Lock Screen view and
    /// tracking in the background begin from the app itself, so the rider is asked to open it once.
    func announceNeedsPhone(for name: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) Started"
        content.body = "Open Commute once to keep this trip live on your Lock Screen and Apple Watch."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: ID.needsPhone, content: content, trigger: nil))
    }

    /// Forgets what has been announced, so the next trip starts fresh.
    func reset() {
        announced = nil
    }

    /// Replaces the standing "time to leave" reminder. Times in the past are dropped.
    func scheduleLeaveNow(at departure: Date, for name: String, arriveBy: Date?) {
        cancelLeaveNow()
        let lead = departure.timeIntervalSinceNow
        guard isAuthorized, lead > 30 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to Leave"
        content.body = arriveBy.map { "Leave now for \(name) to be there by \($0.formatted(date: .omitted, time: .shortened))." }
            ?? "Leave now for \(name)."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: lead, repeats: false)
        center.add(UNNotificationRequest(identifier: ID.leaveNow, content: content, trigger: trigger))
    }

    func cancelLeaveNow() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.leaveNow])
    }
}
