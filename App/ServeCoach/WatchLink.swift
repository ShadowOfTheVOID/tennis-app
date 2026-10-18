import Foundation
import ServeAnalysis
import WatchConnectivity

/// Receives practice sessions from the Apple Watch app and saves them to history.
final class WatchLink: NSObject, WCSessionDelegate {
    /// The key a watch session travels under. Must match the watch app's `WatchLink`.
    static let key = "watchSession"

    private let onSession: @MainActor (WatchSummary) -> Void

    init(onSession: @escaping @MainActor (WatchSummary) -> Void) {
        self.onSession = onSession
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.key] as? Data, let summary = try? JSONDecoder().decode(WatchSummary.self, from: data) else { return }
        Task { @MainActor in onSession(summary) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
