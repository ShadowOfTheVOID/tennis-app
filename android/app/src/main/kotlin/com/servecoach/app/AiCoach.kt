package com.servecoach.app

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.os.StatFs
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ResponseFormat
import com.google.ai.edge.litertlm.SamplerConfig
import com.servecoach.analysis.Coach
import com.servecoach.analysis.CoachModel
import com.servecoach.analysis.CoachReport
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.MatchReport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Downloads, stores and deletes the optional on-device AI coach models. */
class ModelManager(private val context: Context) {
    private val dir = File(context.filesDir, "models")

    fun file(model: CoachModel) = File(dir, model.fileName)

    fun isInstalled(model: CoachModel) = file(model).let { it.exists() && it.length() == model.sizeBytes }

    val deviceRamBytes: Long
        get() = ActivityManager.MemoryInfo().also {
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it)
        }.totalMem

    val freeBytes: Long get() = StatFs(context.filesDir.path).availableBytes

    val recommended: CoachModel? get() = CoachModel.recommended(deviceRamBytes)

    /** Downloads [model], resuming a partial download. Reports progress from 0 to 1. */
    suspend fun download(model: CoachModel, onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        dir.mkdirs()
        val part = File(dir, model.fileName + ".part")
        val needed = model.sizeBytes - part.length()
        if (freeBytes < needed + 200_000_000) {
            throw IOException("Not enough storage: ${model.name} needs ${needed / 1_000_000} MB free.")
        }
        val connection = (URL(model.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            if (part.length() > 0) setRequestProperty("Range", "bytes=${part.length()}-")
        }
        try {
            val resumed = connection.responseCode == HttpURLConnection.HTTP_PARTIAL
            if (!resumed && connection.responseCode != HttpURLConnection.HTTP_OK) {
                throw IOException("Download failed (HTTP ${connection.responseCode}).")
            }
            var written = if (resumed) part.length() else 0L
            connection.inputStream.use { input ->
                FileOutputStream(part, resumed).use { output ->
                    val buffer = ByteArray(1 shl 16)
                    var lastReport = 0L
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        written += n
                        if (written - lastReport > 4_000_000) {
                            lastReport = written
                            onProgress(written.toFloat() / model.sizeBytes)
                        }
                    }
                }
            }
            if (part.length() != model.sizeBytes) {
                throw IOException("Download incomplete. Tap download again to resume.")
            }
            check(part.renameTo(file(model))) { "Could not save the model." }
            onProgress(1f)
        } finally {
            connection.disconnect()
        }
    }

    fun delete(model: CoachModel) {
        file(model).delete()
        File(dir, model.fileName + ".part").delete()
    }
}

/**
 * Turns a stroke or a match into coaching with an on-device language model through LiteRT-LM.
 * No API key and no network: the model file lives on the phone.
 */
class AiCoach(private val context: Context, private val models: ModelManager) {
    private val mutex = Mutex()
    private var engine: Engine? = null
    private var engineModel: CoachModel? = null

    /** The model that will be used, preferring the one the user picked. */
    fun activeModel(preferred: CoachModel?): CoachModel? =
        (listOfNotNull(preferred) + CoachModel.ALL).firstOrNull { models.isInstalled(it) }

    /**
     * Ask the model to coach one stroke. Falls back to the rule-based coach if no model is installed
     * or the model's answer can't be used, so this always returns a report.
     */
    suspend fun review(stroke: ReviewedStroke, hand: Handedness, preferred: CoachModel?): CoachReport = withContext(Dispatchers.Default) {
        val rules = Coach.ruleBased(stroke.result, hand)
        val model = activeModel(preferred) ?: return@withContext rules
        mutex.withLock {
            val engine = engineFor(model)
            val images = if (!model.vision) emptyList() else stroke.result.keyFrames.mapNotNull { stroke.images[it.phase] }
                .mapIndexed { i, bmp -> saveJpeg(bmp, "frame$i.jpg") }
            val contents = images.map { Content.ImageFile(it.absolutePath) } +
                Content.Text(Coach.prompt(stroke.result, hand, hasImages = images.isNotEmpty()))
            ask(engine, Coach.instructions, contents)?.let { Coach.parse(it, stroke.result, hand, model.name) } ?: rules
        }
    }

    /** Ask the model to coach a whole match, from its stroke summaries and footwork. Always returns a report. */
    suspend fun review(match: MatchReport, hand: Handedness, preferred: CoachModel?): CoachReport = withContext(Dispatchers.Default) {
        val rules = Coach.ruleBased(match)
        val model = activeModel(preferred) ?: return@withContext rules
        mutex.withLock {
            val reply = ask(engineFor(model), Coach.matchInstructions, listOf(Content.Text(Coach.matchPrompt(match, hand))))
            reply?.let { Coach.parse(it, match, model.name) } ?: rules
        }
    }

    /** Constrained JSON first; if the model or runtime rejects that, a plain request. Null if both fail. */
    private fun ask(engine: Engine, system: String, contents: List<Content>): String? =
        runCatching { ask(engine, system, contents, constrained = true) }
            .recoverCatching { ask(engine, system, contents, constrained = false) }
            .getOrNull()

    private fun ask(engine: Engine, system: String, contents: List<Content>, constrained: Boolean): String {
        val config = ConversationConfig(
            systemInstruction = Contents.of(system),
            samplerConfig = SamplerConfig(topK = 40, topP = 0.95, temperature = 0.4),
            enableResponseFormat = constrained,
        )
        return engine.createConversation(config).use { conversation ->
            conversation.sendMessage(
                Contents.of(contents),
                responseFormat = if (constrained) ResponseFormat.json(Coach.schema) else null,
            ).toString()
        }
    }

    private fun engineFor(model: CoachModel): Engine {
        engine?.let { if (engineModel == model) return it }
        release()
        // CPU keeps memory use low enough for 4 GB phones; the vision encoder loads on demand.
        val config = EngineConfig(
            modelPath = models.file(model).absolutePath,
            backend = Backend.CPU(),
            visionBackend = if (model.vision) Backend.CPU() else null,
            maxNumTokens = model.maxTokens,
            cacheDir = context.cacheDir.path,
        )
        return Engine(config).also {
            it.initialize()
            engine = it
            engineModel = model
        }
    }

    private fun saveJpeg(bitmap: Bitmap, name: String): File {
        val file = File(context.cacheDir, name)
        val scaled = bitmap.scaledToMax(768)
        FileOutputStream(file).use { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        return file
    }

    /** Free the model's memory, e.g. when the app goes to the background. */
    fun release() {
        engine?.close()
        engine = null
        engineModel = null
    }
}

fun Bitmap.scaledToMax(maxDimension: Int): Bitmap {
    val longest = maxOf(width, height)
    if (longest <= maxDimension) return this
    val scale = maxDimension.toFloat() / longest
    return Bitmap.createScaledBitmap(this, (width * scale).toInt(), (height * scale).toInt(), true)
}
