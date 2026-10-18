package com.servecoach.analysis

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.math.roundToInt

/** A saved serve, small enough to keep hundreds of them. Mirrors `ServeRecord` in the Swift package. */
@Serializable
data class ServeRecord(
    val id: String = UUID.randomUUID().toString(),
    /** Milliseconds since the epoch. */
    val date: Long = System.currentTimeMillis(),
    val score: Int?,
    val trophyScore: Int?,
    val contactScore: Int?,
    /** Label of the most important thing to fix, if any. */
    val topFix: String?,
    val handedness: String,
) {
    companion object {
        fun of(result: ServeResult, hand: Handedness) = ServeRecord(
            score = result.score,
            trophyScore = result.trophy?.score,
            contactScore = result.contact?.score,
            topFix = result.topTip?.label,
            handedness = hand.name.lowercase(),
        )
    }
}

/** Keeps serve history in a JSON file on the device. */
class HistoryStore(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }
    private var cached: List<ServeRecord>? = null

    /** Newest first. */
    @get:Synchronized
    val records: List<ServeRecord>
        get() = load()

    @Synchronized
    fun add(record: ServeRecord) = save((listOf(record) + load()).take(MAX_RECORDS))

    @Synchronized
    fun clear() = save(emptyList())

    private fun load(): List<ServeRecord> = cached ?: runCatching {
        json.decodeFromString<List<ServeRecord>>(file.readText())
    }.getOrDefault(emptyList()).also { cached = it }

    private fun save(records: List<ServeRecord>) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(records))
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
        cached = records
    }

    companion object {
        const val MAX_RECORDS = 500
    }
}

object HistoryStats {
    /**
     * Change in average score between the latest [window] scored serves and the [window] before them.
     * Null until there are enough serves to compare.
     */
    fun trend(records: List<ServeRecord>, window: Int = 5): Int? {
        val scores = records.mapNotNull { it.score }
        if (scores.size < window * 2) return null
        val recent = scores.take(window).sum()
        val earlier = scores.drop(window).take(window).sum()
        return ((recent - earlier).toDouble() / window).roundToInt()
    }

    /** The fix that came up most often in recent serves. */
    fun mostCommonFix(records: List<ServeRecord>, last: Int = 20): String? =
        records.take(last).mapNotNull { it.topFix }.groupingBy { it }.eachCount()
            .entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .firstOrNull()?.key
}
