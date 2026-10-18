import Foundation
import LiteRTLM
import ServeAnalysis
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a serve into coaching, using the best engine this phone has:
/// 1. Gemma 4 through LiteRT-LM, once downloaded (any iPhone with 4 GB+ RAM, e.g. iPhone 11 Pro Max).
///    It also looks at the trophy and contact photos.
/// 2. Apple Intelligence (Foundation Models), on iOS 26 devices that support it.
/// 3. The built-in rule-based coach, everywhere.
/// Everything runs on the phone: no API key, no network, nothing uploaded.
@MainActor
final class AICoach {
    enum EngineKind: Equatable {
        case downloaded(CoachModel)
        case appleIntelligence
        case rules
    }

    private let models: ModelStore
    private let liteRT = LiteRTCoach()

    init(models: ModelStore) {
        self.models = models
    }

    var engine: EngineKind {
        if let model = models.installedModel { return .downloaded(model) }
        if AppleIntelligenceCoach.isAvailable { return .appleIntelligence }
        return .rules
    }

    /// Always returns a report: if an AI engine fails or answers badly, the rule-based coach is used.
    func review(_ serve: ReviewedServe, hand: Handedness) async -> CoachReport {
        let rules = Coach.ruleBased(serve.result)
        switch engine {
        case .downloaded(let model):
            let images = model.vision ? [serve.trophyImage, serve.contactImage].compactMap { $0 } : []
            return (try? await liteRT.review(serve.result, images: images, hand: hand, model: model, path: models.url(for: model))) ?? rules
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return (try? await AppleIntelligenceCoach.review(serve.result, hand: hand)) ?? rules
            }
            #endif
            return rules
        case .rules:
            return rules
        }
    }

    func release() async {
        await liteRT.release()
    }
}

/// Runs a downloaded model with LiteRT-LM. An actor so the engine is used from one place at a time.
private actor LiteRTCoach {
    private var engine: LiteRTLM.Engine?
    private var engineModel: CoachModel?

    func review(_ result: ServeResult, images: [UIImage], hand: Handedness, model: CoachModel, path: URL) async throws -> CoachReport? {
        let engine = try await engine(for: model, path: path)
        let files = try images.enumerated().map { index, image in try Self.saveJPEG(image, name: "frame\(index).jpg") }
        let contents = files.map { LiteRTLM.Content.imageFile($0.path) }
            + [LiteRTLM.Content.text(Coach.prompt(result, hand: hand, hasImages: !files.isEmpty))]

        let reply: String
        do {
            reply = try await ask(engine, contents, constrained: true)
        } catch {
            reply = try await ask(engine, contents, constrained: false)
        }
        return Coach.parse(reply, result: result, modelName: model.name)
    }

    private func ask(_ engine: LiteRTLM.Engine, _ contents: [LiteRTLM.Content], constrained: Bool) async throws -> String {
        let config = LiteRTLM.ConversationConfig(
            systemMessage: LiteRTLM.Message(Coach.instructions),
            samplerConfig: try LiteRTLM.SamplerConfig(topK: 40, topP: 0.95, temperature: 0.4),
            enableResponseFormat: constrained
        )
        let conversation = try await engine.createConversation(with: config)
        let response = try await conversation.sendMessage(
            LiteRTLM.Message(contents: contents),
            responseFormat: constrained ? try LiteRTLM.ResponseFormat.json(schema: Coach.schema) : nil
        )
        return response.toString
    }

    private func engine(for model: CoachModel, path: URL) async throws -> LiteRTLM.Engine {
        if let engine, engineModel == model { return engine }
        release()
        // CPU keeps memory use low enough for 4 GB iPhones; the vision encoder loads on demand.
        let config = try LiteRTLM.EngineConfig(
            modelPath: path.path,
            backend: .cpu(),
            visionBackend: model.vision ? .cpu() : nil,
            maxNumTokens: model.maxTokens,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        self.engine = engine
        engineModel = model
        return engine
    }

    func release() {
        engine = nil
        engineModel = nil
    }

    private static func saveJPEG(_ image: UIImage, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard let data = image.resized(maxDimension: 768).jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

// MARK: - Apple Intelligence

enum AppleIntelligenceCoach {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension AppleIntelligenceCoach {
    @Generable
    struct Report {
        @Guide(description: "Two or three sentences summarising the serve posture.")
        var summary: String
        @Guide(description: "One entry per measured check, using the id in square brackets.")
        var measurementReview: [Review]
        @Guide(description: "Things the player already does well.")
        var strengths: [String]
        @Guide(description: "At most three improvements, most important first.")
        var improvements: [Improvement]
        @Guide(description: "One sentence on what to focus on next practice.")
        var nextSessionFocus: String
    }

    @Generable
    struct Review {
        @Guide(description: "The check id from the square brackets, e.g. knee-bend.")
        var checkId: String
        @Guide(description: "Whether this measurement looks reliable.")
        var trustworthy: Bool
        @Guide(description: "A short reason, under 15 words.")
        var note: String
    }

    @Generable
    struct Improvement {
        var title: String
        @Guide(description: "Why this matters for the serve.")
        var why: String
        @Guide(description: "A short on-court cue for fixing it.")
        var how: String
        @Guide(description: "One simple drill, different from the cue.")
        var drill: String
    }

    static func review(_ result: ServeResult, hand: Handedness) async throws -> CoachReport? {
        let session = LanguageModelSession(instructions: Coach.instructions)
        let report = try await session.respond(to: Coach.prompt(result, hand: hand, hasImages: false), generating: Report.self).content
        // Round-trip through the shared parser so both AI engines get the same clean-up and fallbacks.
        let json: [String: Any] = [
            "summary": report.summary,
            "measurement_review": report.measurementReview.map { ["check_id": $0.checkId, "trustworthy": $0.trustworthy, "note": $0.note] },
            "strengths": report.strengths,
            "improvements": report.improvements.map { ["title": $0.title, "why": $0.why, "how": $0.how, "drill": $0.drill] },
            "next_session_focus": report.nextSessionFocus,
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        return Coach.parse(text, result: result, modelName: "Apple Intelligence")
    }
}
#endif
