import CoreMotion
import ServeAnalysis
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct ServeCoachWatchApp: App {
    @State private var session = WristSession()

    var body: some Scene {
        WindowGroup {
            WristView().environment(session)
        }
    }
}

/// Wear it on your hitting wrist: counts swings and measures wrist speed, then sends the session to the iPhone.
struct WristView: View {
    @Environment(WristSession.self) private var session

    var body: some View {
        VStack(spacing: 8) {
            if session.running {
                Text("\(session.count) swings").font(.title2.bold())
                if let last = session.last {
                    Text("Last: \(Int(last.peakRotation.rounded()))°/s").font(.footnote)
                }
                Button("Finish") { session.stop() }.tint(.red)
            } else {
                Text("Serve Coach").font(.headline)
                Text(session.status ?? "Wear on your hitting wrist, then start.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Start") { session.start() }.tint(.green)
            }
        }
        .padding()
    }
}

/// Reads the watch's motion at 100 Hz and finds swings. An extended runtime session keeps it
/// running when you lower your wrist between shots (up to an hour).
@MainActor
@Observable
final class WristSession: NSObject {
    private(set) var running = false
    private(set) var count = 0
    private(set) var last: WristSwing?
    private(set) var status: String?

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let queue = OperationQueue()
    @ObservationIgnored private var detector = WristSwingDetector()
    @ObservationIgnored private var swings: [WristSwing] = []
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var runtime: WKExtendedRuntimeSession?

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start() {
        guard motion.isDeviceMotionAvailable else {
            status = "This watch can't measure motion."
            return
        }
        detector = WristSwingDetector()
        swings = []
        count = 0
        last = nil
        status = nil
        started = Date()
        let runtime = WKExtendedRuntimeSession()
        runtime.start()
        self.runtime = runtime

        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let data, let self else { return }
            // Device motion splits gravity from your acceleration; add them back for the total, in g.
            let a = data.userAcceleration, g = data.gravity, r = data.rotationRate
            let sample = MotionSample(time: data.timestamp, ax: a.x + g.x, ay: a.y + g.y, az: a.z + g.z, gx: r.x, gy: r.y, gz: r.z)
            Task { @MainActor in self.add(sample) }
        }
        running = true
    }

    private func add(_ sample: MotionSample) {
        guard running, let swing = detector.add(sample) else { return }
        swings.append(swing)
        count = swings.count
        last = swing
        WKInterfaceDevice.current().play(.click)
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        runtime?.invalidate()
        runtime = nil
        running = false
        let summary = WatchSummary.of(swings, seconds: Date().timeIntervalSince(started), date: started)
        status = "\(summary.swings) swings. \(summary.verdict)."
        send(summary)
    }

    /// Queued by WatchConnectivity, so it reaches the iPhone even if it's out of range right now.
    private func send(_ summary: WatchSummary) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(summary) else {
            status = (status ?? "") + " Couldn't reach the iPhone app."
            return
        }
        WCSession.default.transferUserInfo([WatchLink.key: data])
        status = (status ?? "") + " Sent to your iPhone."
    }
}

extension WristSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}

/// The key a watch session travels under. Must match the iPhone app's `WatchLink`.
enum WatchLink {
    static let key = "watchSession"
}
