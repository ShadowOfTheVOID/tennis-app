package com.servecoach.analysis

/**
 * An on-device language model the app can download. Mirrors `CoachModel` in the Swift package.
 * It is open-licensed and downloads from Hugging Face with no account or key.
 */
data class CoachModel(
    val id: String,
    val name: String,
    val summary: String,
    val url: String,
    val fileName: String,
    val sizeBytes: Long,
    /** Whether the model can look at the serve photos. */
    val vision: Boolean,
    /** Recommended minimum device RAM. */
    val minRamBytes: Long,
    /** KV-cache size; vision prompts need room for the two images. */
    val maxTokens: Int,
) {
    companion object {
        val GEMMA_4 = CoachModel(
            id = "gemma-4-e2b",
            name = "Gemma 4 E2B",
            summary = "Looks at your trophy and contact photos to double-check the measurements. Best coaching.",
            url = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm",
            fileName = "gemma-4-E2B-it.litertlm",
            sizeBytes = 2_588_147_712,
            vision = true,
            minRamBytes = 3_500_000_000,
            maxTokens = 4096,
        )

        // Smaller models (e.g. Qwen3 0.6B) were tried and could not produce usable coaching.
        val ALL = listOf(GEMMA_4)

        /** The best model this device can comfortably run, or null if none (the built-in coach is used). */
        fun recommended(ramBytes: Long) = ALL.firstOrNull { ramBytes >= it.minRamBytes }
    }
}
