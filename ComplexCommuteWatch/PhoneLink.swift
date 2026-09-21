import CommuteCore
import Foundation
import Observation
import WatchConnectivity

/// The Watch's end of the line to the phone, where the planning is done and the trip is kept.
@Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    private(set) var context = WatchContext(sentAt: .distantPast)
    private(set) var isReachable = false
    /// The command the phone is busy with.
    private(set) var busy: WatchCommand?
    var error: String?

    func activate() {
        guard WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone to do something, and takes how things stand afterwards from its answer.
    func send(_ command: WatchCommand) async {
        guard busy == nil, let data = try? JSONEncoder().encode(command) else { return }
        guard WCSession.default.isReachable else {
            if command != .refresh { error = "Your iPhone isn't in reach." }
            return
        }
        busy = command
        defer { busy = nil }

        let answer: Data? = await withCheckedContinuation { continuation in
            WCSession.default.sendMessageData(data, replyHandler: { continuation.resume(returning: $0) },
                                              errorHandler: { _ in continuation.resume(returning: nil) })
        }
        guard let answer, let reply = try? JSONDecoder().decode(WatchReply.self, from: answer) else {
            if command != .refresh { error = "Your iPhone didn't answer." }
            return
        }
        context = reply.context
        error = reply.error
    }

    /// Older news can arrive after newer: a context waiting from earlier, behind a message sent just now.
    private func receive(_ data: Data) {
        guard let received = try? JSONDecoder().decode(WatchContext.self, from: data), received.sentAt > context.sentAt else { return }
        context = received
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let waiting = session.receivedApplicationContext[WatchLink.payloadKey] as? Data
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isReachable = isReachable
            if let waiting { self.receive(waiting) }
            await self.send(.refresh)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isReachable = isReachable
            if isReachable { await self.send(.refresh) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLink.payloadKey] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.receive(messageData) }
    }
}
