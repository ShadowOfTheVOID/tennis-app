import Foundation

/// A saved serve, small enough to keep hundreds of them. Mirrors `ServeRecord` on Android.
public struct ServeRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let score: Int?
    public let trophyScore: Int?
    public let contactScore: Int?
    /// Label of the most important thing to fix, if any.
    public let topFix: String?
    public let handedness: String

    public init(id: UUID = UUID(), date: Date = Date(), result: ServeResult, hand: Handedness) {
        self.id = id
        self.date = date
        score = result.score
        trophyScore = result.trophy?.score
        contactScore = result.contact?.score
        topFix = result.topTip?.label
        handedness = hand.rawValue
    }
}

/// Keeps serve history in a JSON file on the device.
public final class HistoryStore: @unchecked Sendable {
    public static let maxRecords = 500

    private let url: URL
    private let lock = NSLock()
    private var cached: [ServeRecord]?

    public init(url: URL) {
        self.url = url
    }

    /// Newest first.
    public var records: [ServeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    public func add(_ record: ServeRecord) throws {
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

    private func load() -> [ServeRecord] {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([ServeRecord].self, from: $0) } ?? []
        cached = loaded
        return loaded
    }

    private func save(_ records: [ServeRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
        cached = records
    }
}

public enum HistoryStats {
    /// Change in average score between the latest `window` scored serves and the `window` before them.
    /// Nil until there are enough serves to compare.
    public static func trend(_ records: [ServeRecord], window: Int = 5) -> Int? {
        let scores = records.compactMap(\.score)
        guard scores.count >= window * 2 else { return nil }
        let recent = scores.prefix(window).reduce(0, +)
        let earlier = scores.dropFirst(window).prefix(window).reduce(0, +)
        return Int((Double(recent - earlier) / Double(window)).rounded())
    }

    /// The fix that came up most often in recent serves.
    public static func mostCommonFix(_ records: [ServeRecord], last: Int = 20) -> String? {
        let counts = Dictionary(records.prefix(last).compactMap(\.topFix).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
