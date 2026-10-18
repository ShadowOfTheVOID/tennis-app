import Foundation
import Observation
import ServeAnalysis

/// App-wide state shared by every tab: practice history, AI models and coaching results.
@MainActor
@Observable
final class AppState {
    let models = ModelStore()
    @ObservationIgnored private let coach: AICoach
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private var watch: WatchLink?

    private(set) var history: [PracticeRecord] = []
    /// Coaching reports already produced, by stroke or match id, so reopening a review doesn't re-run the model.
    private(set) var reports: [UUID: CoachReport] = [:]
    private(set) var coaching: Set<UUID> = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyStore = HistoryStore(url: support.appendingPathComponent("history.json"))
        coach = AICoach(models: models)
        history = historyStore.records
        watch = WatchLink { [weak self] summary in
            guard let self else { return }
            let hand = Handedness(rawValue: UserDefaults.standard.string(forKey: "handedness") ?? "") ?? .right
            save(PracticeRecord(watch: summary, hand: hand))
        }
    }

    /// Save a finished stroke to history.
    func record(_ stroke: ReviewedStroke, hand: Handedness) {
        save(PracticeRecord(id: stroke.id, stroke: stroke.result, hand: hand))
    }

    /// The best saved stroke of the same kind, not counting this one, for the ghost overlay.
    func best(for stroke: ReviewedStroke) -> PracticeRecord? {
        PracticeStats.best(history.filter { $0.id != stroke.id }, kind: stroke.result.type.rawValue)
    }

    /// Save an analysed match to history.
    func record(_ match: AnalyzedMatch, hand: Handedness) {
        save(PracticeRecord(match: match.report, hand: hand))
    }

    private func save(_ record: PracticeRecord) {
        try? historyStore.add(record)
        history.insert(record, at: 0)
    }

    func clearHistory() {
        try? historyStore.clear()
        history = []
    }

    /// Which engine "How do I improve?" will use right now.
    var coachEngine: AICoach.EngineKind { coach.engine }

    func requestCoaching(_ stroke: ReviewedStroke, hand: Handedness) {
        coachInBackground(stroke.id) { await $0.review(stroke, hand: hand) }
    }

    func requestCoaching(_ match: AnalyzedMatch, hand: Handedness) {
        coachInBackground(match.id) { await $0.review(match.report, hand: hand) }
    }

    private func coachInBackground(_ id: UUID, _ work: @escaping (AICoach) async -> CoachReport) {
        guard !coaching.contains(id) else { return }
        coaching.insert(id)
        Task {
            reports[id] = await work(coach)
            coaching.remove(id)
        }
    }

    /// Free the AI model's memory, e.g. when the app goes to the background.
    func releaseModel() {
        Task { await coach.release() }
    }
}
