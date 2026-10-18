import Foundation

/// An on-device language model the app can download. Mirrors `CoachModel` on Android.
/// It is open-licensed and downloads from Hugging Face with no account or key.
public struct CoachModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let url: URL
    public let fileName: String
    public let sizeBytes: Int64
    /// Whether the model can look at the serve photos.
    public let vision: Bool
    /// Recommended minimum device RAM.
    public let minRAMBytes: UInt64
    /// KV-cache size; vision prompts need room for the two images.
    public let maxTokens: Int

    public static let gemma4 = CoachModel(
        id: "gemma-4-e2b",
        name: "Gemma 4 E2B",
        summary: "Looks at your trophy and contact photos to double-check the measurements. Best coaching.",
        url: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
        fileName: "gemma-4-E2B-it.litertlm",
        sizeBytes: 2_588_147_712,
        vision: true,
        minRAMBytes: 3_500_000_000,
        maxTokens: 4096
    )

    // Smaller models (e.g. Qwen3 0.6B) were tried and could not produce usable coaching.
    public static let all = [gemma4]

    /// The best model this device can comfortably run, or nil if none (the built-in coach is used).
    public static func recommended(forRAM ram: UInt64) -> CoachModel? {
        all.first { ram >= $0.minRAMBytes }
    }
}
