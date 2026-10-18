import Foundation

/// A saved stroke or match, small enough to keep hundreds of them. Mirrors `PracticeRecord` on Android.
public struct PracticeRecord: Codable, Identifiable, Sendable, Equatable {
    public static let matchKind = "match"

    public let id: UUID
    public let date: Date
    /// A `StrokeType` raw value, or `matchKind`.
    public let kind: String
    public let score: Int?
    /// One line of detail, e.g. "Trophy 80 · Contact 60" or "38 strokes in 9 rallies".
    public let detail: String
    /// The most important thing to fix, if any.
    public let topFix: String?
    public let handedness: String

    public init(id: UUID = UUID(), date: Date = Date(), stroke: StrokeResult, hand: Handedness) {
        self.id = id
        self.date = date
        kind = stroke.type.rawValue
        score = stroke.score
        detail = stroke.evaluations.map { "\($0.phase.title) \($0.score.map(String.init) ?? "—")" }.joined(separator: " · ")
        topFix = stroke.topTip?.label
        handedness = hand.rawValue
    }

    public init(id: UUID = UUID(), date: Date = Date(), match: MatchReport, hand: Handedness) {
        self.id = id
        self.date = date
        kind = Self.matchKind
        score = match.score
        detail = match.countsText
        topFix = Coach.ruleBased(match).improvements.first?.title
        handedness = hand.rawValue
    }

    /// "Forehand", "Match", ...
    public var title: String { StrokeType(rawValue: kind)?.title ?? "Match" }
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
