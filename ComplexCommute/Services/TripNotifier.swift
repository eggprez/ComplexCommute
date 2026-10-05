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
    /// The rider picked a train from the "which train?" notification, by its place in the question.
    @ObservationIgnored var onTrainAnswer: ((Int) -> Void)? {
        didSet { responder.onTrainAnswer = onTrainAnswer }
    }

    private let center = UNUserNotificationCenter.current()
    /// Must be the center's delegate before launch finishes, or an answer that woke the app is lost.
    @ObservationIgnored private let responder = NotificationResponder()

    init() {
        center.delegate = responder
    }

    private enum ID {
        static let leaveNow = "leave-now"
        static let fasterOption = "faster-option"
        static let whichTrain = "which-train"
        static func train(_ option: Int) -> String { "train.\(option)" }
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

    /// The trip moved itself to a plan that gets there much sooner. Said once per plan.
    func announceSwitch(to itinerary: Itinerary, saving: TimeInterval) {
        guard isAuthorized, announced != itinerary.id else { return }
        announced = itinerary.id

        let content = UNMutableNotificationContent()
        content.title = "Switched to a Faster Way"
        let routes = itinerary.legs.flatMap(\.option.rides).map(\.routeName).joined(separator: " → ")
        content.body = "\(Int(saving / 60)) min sooner\(routes.isEmpty ? "" : " by \(routes)"). Arrive \(itinerary.arrival.formatted(date: .omitted, time: .shortened))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: ID.fasterOption, content: content, trigger: nil))
    }

    /// Two trains fit the rider's location about equally: ask which, with a button for each, so it's answered
    /// from the Lock Screen without opening the app. Asked at most once a ride.
    func askWhichTrain(_ options: [Ride]) {
        guard isAuthorized, options.count >= 2 else { return }
        let actions = options.enumerated().map { index, ride in
            UNNotificationAction(identifier: ID.train(index), title: Self.name(ride, among: options), options: [])
        }
        center.setNotificationCategories([UNNotificationCategory(identifier: ID.whichTrain, actions: actions, intentIdentifiers: [])])

        let content = UNMutableNotificationContent()
        let kinds = Set(options.map(\.vehicle))
        content.title = kinds.count == 1 ? "Which \(options[0].vehicle.title)?" : "Which One?"
        content.body = "Can't tell whether you're on the \(options.map { Self.name($0, among: options) }.joined(separator: " or the ")). "
            + "Pick one so arrival times follow it."
        content.categoryIdentifier = ID.whichTrain
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: ID.whichTrain, content: content, trigger: nil))
    }

    /// The question is answered, or the location settled it: take it off the Lock Screen.
    func withdrawWhichTrain() {
        center.removeDeliveredNotifications(withIdentifiers: [ID.whichTrain])
    }

    /// "4:13 PM R", or with where it's going when that's what tells them apart (a local and an express).
    private static func name(_ ride: Ride, among options: [Ride]) -> String {
        let time = ride.board.formatted(date: .omitted, time: .shortened)
        let sameName = options.allSatisfy { $0.routeName == ride.routeName }
        let sameTime = options.allSatisfy { abs($0.board.timeIntervalSince(ride.board)) < 60 }
        if sameTime, let headsign = ride.headsign { return "\(ride.routeName) to \(headsign)" }
        return sameName || ride.routeName.isEmpty ? "\(time) \(ride.routeName)" : "\(ride.routeName) at \(time)"
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

/// Hears the rider's answer to a notification. Nothing is presented while the app is in front: the trip screen
/// asks there itself.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    var onTrainAnswer: ((Int) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action.hasPrefix("train."), let option = Int(action.dropFirst("train.".count)) else { return }
        await MainActor.run { onTrainAnswer?(option) }
    }
}
