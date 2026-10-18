import Foundation
import Observation
import ServeAnalysis

/// App-wide state shared by every tab: serve history, AI models and coaching results.
@MainActor
@Observable
final class AppState {
    let models = ModelStore()
    @ObservationIgnored private let coach: AICoach
    @ObservationIgnored private let historyStore: HistoryStore

    private(set) var history: [ServeRecord] = []
    /// Coaching reports already produced, by serve id, so reopening a review doesn't re-run the model.
    private(set) var reports: [UUID: CoachReport] = [:]
    private(set) var coaching: Set<UUID> = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyStore = HistoryStore(url: support.appendingPathComponent("history.json"))
        coach = AICoach(models: models)
        history = historyStore.records
    }

    /// Save a finished serve to history.
    func record(_ serve: ReviewedServe, hand: Handedness) {
        let record = ServeRecord(result: serve.result, hand: hand)
        try? historyStore.add(record)
        history.insert(record, at: 0)
    }

    func clearHistory() {
        try? historyStore.clear()
        history = []
    }

    /// Which engine "How do I improve?" will use right now.
    var coachEngine: AICoach.EngineKind { coach.engine }

    func requestCoaching(_ serve: ReviewedServe, hand: Handedness) {
        guard !coaching.contains(serve.id) else { return }
        coaching.insert(serve.id)
        Task {
            reports[serve.id] = await coach.review(serve, hand: hand)
            coaching.remove(serve.id)
        }
    }

    /// Free the AI model's memory, e.g. when the app goes to the background.
    func releaseModel() {
        Task { await coach.release() }
    }
}
