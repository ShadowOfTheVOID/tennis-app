import Foundation

/// A saved stroke or match, small enough to keep hundreds of them. Mirrors `PracticeRecord` on Android.
public struct PracticeRecord: Codable, Identifiable, Sendable, Equatable {
    public static let matchKind = "match"
    public static let watchKind = "watch"

    /// One check's result, kept so progress can be charted per check.
    public struct CheckSnapshot: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        /// A `Status` raw value.
        public let status: String
    }

    public let id: UUID
    public let date: Date
    /// A `StrokeType` raw value, or `matchKind`.
    public let kind: String
    public let score: Int?
    /// One line of detail, e.g. "Trophy position 80 · Contact 60" or "38 strokes in about 9 rallies".
    public let detail: String
    /// The most important thing to fix, if any.
    public let topFix: String?
    public let handedness: String
    public let checks: [CheckSnapshot]
    /// Peak hitting-hand speed in metres per second (estimated).
    public let swingSpeed: Double?
    /// Serve rhythm: seconds from trophy position to contact.
    public let tempo: Double?
    /// Which way the player faced (+1 right, -1 left), for lining up ghost poses.
    public let direction: Double?
    /// Pose at each key moment (phase raw value → joint raw value → [x, y, confidence]), for the ghost overlay.
    public let keyPoses: [String: [String: [Double]]]

    public init(id: UUID = UUID(), date: Date = Date(), stroke: StrokeResult, hand: Handedness) {
        self.id = id
        self.date = date
        kind = stroke.type.rawValue
        score = stroke.score
        detail = stroke.evaluations.map { "\($0.phase.title) \($0.score.map(String.init) ?? "—")" }.joined(separator: " · ")
        topFix = stroke.topTip?.label
        handedness = hand.rawValue
        checks = stroke.checks.map { CheckSnapshot(id: $0.id, label: $0.label, status: $0.status.rawValue) }
        swingSpeed = stroke.swingSpeed
        tempo = stroke.tempo
        direction = stroke.direction
        keyPoses = Dictionary(stroke.keyFrames.map { ($0.phase.rawValue, Self.encode($0.frame.pose)) }, uniquingKeysWith: { a, _ in a })
    }

    public init(id: UUID = UUID(), date: Date = Date(), match: MatchReport, hand: Handedness) {
        self.id = id
        self.date = date
        kind = Self.matchKind
        score = match.score
        detail = match.countsText
        topFix = Coach.ruleBased(match).improvements.first?.title
        handedness = hand.rawValue
        checks = []
        let speeds = match.strokes.compactMap(\.swingSpeed)
        swingSpeed = speeds.max()
        tempo = nil
        direction = nil
        keyPoses = [:]
    }

    public init(watch: WatchSummary, hand: Handedness) {
        id = UUID()
        date = watch.date
        kind = Self.watchKind
        score = nil
        detail = String(format: "%d swings in %d min · fastest ≈ %@°/s · %@", watch.swings, Int((watch.seconds / 60).rounded()),
                        Self.grouped(watch.best), String(watch.verdict.split(separator: ":")[0]))
        topFix = nil
        handedness = hand.rawValue
        checks = []
        swingSpeed = watch.racketSpeed
        tempo = nil
        direction = nil
        keyPoses = [:]
    }

    /// e.g. "1,146", matching Kotlin's "%,.0f" in the US locale.
    private static func grouped(_ v: Double) -> String {
        let n = Int(v.rounded())
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// "Forehand", "Match", ...
    public var title: String { StrokeType(rawValue: kind)?.title ?? (kind == Self.watchKind ? "Watch session" : "Match") }

    /// The saved pose at `phase`, if any.
    public func pose(at phase: Phase) -> Pose? {
        guard let joints = keyPoses[phase.rawValue] else { return nil }
        var decoded: [Joint: Point] = [:]
        for (name, v) in joints {
            guard let joint = Joint(rawValue: name), v.count == 3 else { continue }
            decoded[joint] = Point(x: v[0], y: v[1], confidence: v[2])
        }
        return Pose(joints: decoded)
    }

    static func encode(_ pose: Pose) -> [String: [Double]] {
        Dictionary(pose.joints.map { ($0.key.rawValue, [$0.value.x, $0.value.y, $0.value.confidence]) }, uniquingKeysWith: { a, _ in a })
    }

    enum CodingKeys: String, CodingKey {
        case id, date, kind, score, detail, topFix, handedness, checks, swingSpeed, tempo, direction, keyPoses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decode(String.self, forKey: .kind)
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        topFix = try c.decodeIfPresent(String.self, forKey: .topFix)
        handedness = try c.decodeIfPresent(String.self, forKey: .handedness) ?? Handedness.right.rawValue
        checks = try c.decodeIfPresent([CheckSnapshot].self, forKey: .checks) ?? []
        swingSpeed = try c.decodeIfPresent(Double.self, forKey: .swingSpeed)
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo)
        direction = try c.decodeIfPresent(Double.self, forKey: .direction)
        keyPoses = try c.decodeIfPresent([String: [String: [Double]]].self, forKey: .keyPoses) ?? [:]
    }
}

/// Keeps practice history in a JSON file on the device.
public final class HistoryStore: @unchecked Sendable {
    public static let maxRecords = 500

    private let url: URL
    private let lock = NSLock()
    private var cached: [PracticeRecord]?

    public init(url: URL) {
        self.url = url
    }

    /// Newest first.
    public var records: [PracticeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    public func add(_ record: PracticeRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        all.insert(record, at: 0)
        if all.count > Self.maxRecords { all.removeLast(all.count - Self.maxRecords) }
        try save(all)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try save([])
    }

    private func load() -> [PracticeRecord] {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([PracticeRecord].self, from: $0) } ?? []
        cached = loaded
        return loaded
    }

    private func save(_ records: [PracticeRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
        cached = records
    }
}

public enum HistoryStats {
    /// Change in average score between the latest `window` scored records and the `window` before them.
    /// Pass records of one kind for a meaningful trend.
    /// Nil until there are enough records to compare.
    public static func trend(_ records: [PracticeRecord], window: Int = 5) -> Int? {
        let scores = records.compactMap(\.score)
        guard scores.count >= window * 2 else { return nil }
        let recent = scores.prefix(window).reduce(0, +)
        let earlier = scores.dropFirst(window).prefix(window).reduce(0, +)
        return Int((Double(recent - earlier) / Double(window)).rounded())
    }

    /// The fix that came up most often in recent records.
    public static func mostCommonFix(_ records: [PracticeRecord], last: Int = 20) -> String? {
        let counts = Dictionary(records.prefix(last).compactMap(\.topFix).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
