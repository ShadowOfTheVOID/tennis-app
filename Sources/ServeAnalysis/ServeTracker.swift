import Foundation

/// The analysed key moments of one serve.
public struct ServeResult: Sendable {
    public let trophyFrame: Frame?
    public let contactFrame: Frame?
    public let trophy: Evaluation?
    public let contact: Evaluation?

    /// Average of the trophy and contact scores that could be measured.
    public var score: Int? {
        let scores = [trophy?.score, contact?.score].compactMap { $0 }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    /// Every check from both key moments.
    public var checks: [Check] { (trophy?.checks ?? []) + (contact?.checks ?? []) }

    /// The most useful single thing to work on: the first failing check, then the first warning.
    public var topTip: Check? {
        checks.first { $0.status == .bad } ?? checks.first { $0.status == .warn }
    }
}

extension ServeAnalyzer {
    /// Find the key frames of a recorded serve and evaluate them.
    public static func analyze(_ frames: [Frame], hand: Handedness) -> ServeResult {
        let (t, c) = keyFrames(in: frames, hand: hand)
        return ServeResult(
            trophyFrame: t,
            contactFrame: c,
            trophy: t.map { trophy($0.pose, hand: hand) },
            contact: c.map { contact($0.pose, hand: hand) }
        )
    }
}

/// Watches a live stream of poses and reports a `ServeResult` each time a serve finishes,
/// i.e. when the player leaves the contact position.
public struct ServeTracker: Sendable {
    public let hand: Handedness
    /// How many seconds of history to search for the trophy position.
    public let window: Double

    private var buffer: [Frame] = []
    private var inContact = false

    public init(hand: Handedness, window: Double = 3) {
        self.hand = hand
        self.window = window
    }

    public mutating func add(_ frame: Frame) -> ServeResult? {
        buffer.append(frame)
        buffer.removeAll { $0.time < frame.time - window }

        if ServeAnalyzer.phase(of: frame.pose, hand: hand) == .contact {
            inContact = true
            return nil
        }
        guard inContact else { return nil }
        inContact = false
        let result = ServeAnalyzer.analyze(buffer, hand: hand)
        buffer.removeAll()
        return result
    }
}
