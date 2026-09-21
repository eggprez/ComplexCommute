import CommuteCore
import Foundation
import WatchConnectivity

/// The phone's end of the line to the Watch app: sends it the trip and the saved commutes, and
/// carries out what the rider asks for from the wrist.
final class WatchBridge: NSObject, WCSessionDelegate {
    /// Carries out a command and says how things stand afterwards.
    var handler: ((WatchCommand) async -> WatchReply)?

    private var sent: WatchContext?
    /// The newest context there is, sent or not: the session may not be up yet, or the Watch app not installed.
    private var latest: WatchContext?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the Watch everything it shows, if any of it changed.
    func send(_ context: WatchContext) {
        guard WCSession.isSupported() else { return }
        latest = context
        if let sent, sent.trip == context.trip, sent.commutes == context.commutes { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled, let data = try? JSONEncoder().encode(context) else { return }
        sent = context
        // The context is what the Watch app finds waiting whenever it next runs; the message gets
        // there at once when it is running now.
        try? session.updateApplicationContext([WatchLink.payloadKey: data])
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil)
        }
    }

    private func respond(to message: Data) async -> Data {
        var reply = WatchReply(context: latest ?? WatchContext(), error: "Commute on iPhone didn't understand that. Update both apps.")
        if let command = try? JSONDecoder().decode(WatchCommand.self, from: message), let handler {
            reply = await handler(command)
        }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            if let latest = self.latest { self.send(latest) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The rider switched to another Watch; start talking to that one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            // A Watch app installed since the last send has seen nothing yet.
            self.sent = nil
            if let latest = self.latest { self.send(latest) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            reply(await self.respond(to: messageData))
        }
    }
}
