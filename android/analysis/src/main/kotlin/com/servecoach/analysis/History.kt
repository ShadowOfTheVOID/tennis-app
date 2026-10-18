package com.servecoach.analysis

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.math.roundToInt

/** A saved stroke or match, small enough to keep hundreds of them. Mirrors `PracticeRecord` in the Swift package. */
@Serializable
data class PracticeRecord(
    val id: String = UUID.randomUUID().toString(),
    /** Milliseconds since the epoch. */
    val date: Long = System.currentTimeMillis(),
    /** A [StrokeType.key], or [MATCH_KIND]. */
    val kind: String,
    val score: Int?,
    /** One line of detail, e.g. "Trophy position 80 · Contact 60" or "38 strokes in about 9 rallies". */
    val detail: String,
    /** The most important thing to fix, if any. */
    val topFix: String?,
    val handedness: String,
) {
    /** "Forehand", "Match", ... */
    val title: String get() = StrokeType.entries.firstOrNull { it.key == kind }?.title ?: "Match"

    companion object {
        const val MATCH_KIND = "match"

        fun of(stroke: StrokeResult, hand: Handedness) = PracticeRecord(
            kind = stroke.type.key,
            score = stroke.score,
            detail = stroke.evaluations.joinToString(" · ") { "${it.phase.title} ${it.score ?: "—"}" },
            topFix = stroke.topTip?.label,
            handedness = hand.name.lowercase(),
        )

        fun of(match: MatchReport, hand: Handedness) = PracticeRecord(
            kind = MATCH_KIND,
            score = match.score,
            detail = match.countsText,
            topFix = Coach.ruleBased(match).improvements.firstOrNull()?.title,
            handedness = hand.name.lowercase(),
        )
    }
}

/** Keeps practice history in a JSON file on the device. */
class HistoryStore(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }
    private var cached: List<PracticeRecord>? = null

    /** Newest first. */
    @get:Synchronized
    val records: List<PracticeRecord>
        get() = load()

    @Synchronized
    fun add(record: PracticeRecord) = save((listOf(record) + load()).take(MAX_RECORDS))

    @Synchronized
    fun clear() = save(emptyList())

    private fun load(): List<PracticeRecord> = cached ?: runCatching {
        json.decodeFromString<List<PracticeRecord>>(file.readText())
    }.getOrDefault(emptyList()).also { cached = it }

    private fun save(records: List<PracticeRecord>) {
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
     * Change in average score between the latest [window] scored records and the [window] before them.
     * Pass records of one kind for a meaningful trend. Null until there are enough records to compare.
     */
    fun trend(records: List<PracticeRecord>, window: Int = 5): Int? {
        val scores = records.mapNotNull { it.score }
        if (scores.size < window * 2) return null
        val recent = scores.take(window).sum()
        val earlier = scores.drop(window).take(window).sum()
        return ((recent - earlier).toDouble() / window).roundToInt()
    }

    /** The fix that came up most often in recent records. */
    fun mostCommonFix(records: List<PracticeRecord>, last: Int = 20): String? =
        records.take(last).mapNotNull { it.topFix }.groupingBy { it }.eachCount()
            .entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .firstOrNull()?.key
}
