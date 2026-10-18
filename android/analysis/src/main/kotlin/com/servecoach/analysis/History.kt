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
    val checks: List<CheckSnapshot> = emptyList(),
    /** Peak hitting-hand speed in metres per second (estimated). */
    val swingSpeed: Double? = null,
    /** Serve rhythm: seconds from trophy position to contact. */
    val tempo: Double? = null,
    /** Which way the player faced (+1 right, -1 left), for lining up ghost poses. */
    val direction: Double? = null,
    /** Pose at each key moment (phase key → joint key → [x, y, confidence]), for the ghost overlay. */
    val keyPoses: Map<String, Map<String, List<Double>>> = emptyMap(),
) {
    /** One check's result, kept so progress can be charted per check. */
    @Serializable
    data class CheckSnapshot(val id: String, val label: String, /** A [Status] key, e.g. "good". */ val status: String)

    /** "Forehand", "Match", ... */
    val title: String get() = StrokeType.entries.firstOrNull { it.key == kind }?.title ?: if (kind == WATCH_KIND) "Watch session" else "Match"

    /** The saved pose at [phase], if any. */
    fun pose(phase: Phase): Pose? {
        val joints = keyPoses[phase.key] ?: return null
        return Pose(joints.mapNotNull { (name, v) ->
            val joint = Joint.entries.firstOrNull { it.key == name } ?: return@mapNotNull null
            if (v.size != 3) null else joint to Point(v[0], v[1], v[2])
        }.toMap())
    }

    companion object {
        const val MATCH_KIND = "match"
        const val WATCH_KIND = "watch"

        fun of(watch: WatchSummary, hand: Handedness) = PracticeRecord(
            date = watch.date,
            kind = WATCH_KIND,
            score = null,
            detail = "%d swings in %d min · fastest ≈ %,.0f°/s · %s".format(
                java.util.Locale.US, watch.swings, (watch.seconds / 60).roundToInt(), watch.best, watch.verdict.substringBefore(":")),
            topFix = null,
            handedness = hand.name.lowercase(),
            swingSpeed = watch.racketSpeed,
        )

        fun of(stroke: StrokeResult, hand: Handedness, date: Long = System.currentTimeMillis()) = PracticeRecord(
            date = date,
            kind = stroke.type.key,
            score = stroke.score,
            detail = stroke.evaluations.joinToString(" · ") { "${it.phase.title} ${it.score ?: "—"}" },
            topFix = stroke.topTip?.label,
            handedness = hand.name.lowercase(),
            checks = stroke.checks.map { CheckSnapshot(it.id, it.label, it.status.name.lowercase()) },
            swingSpeed = stroke.swingSpeed,
            tempo = stroke.tempo,
            direction = stroke.direction,
            keyPoses = stroke.keyFrames.associate { k -> k.phase.key to k.frame.pose.joints.entries.associate { (j, p) -> j.key to listOf(p.x, p.y, p.confidence) } },
        )

        fun of(match: MatchReport, hand: Handedness) = PracticeRecord(
            kind = MATCH_KIND,
            score = match.score,
            detail = match.countsText,
            topFix = Coach.ruleBased(match).improvements.firstOrNull()?.title,
            handedness = hand.name.lowercase(),
            swingSpeed = match.strokes.mapNotNull { it.swingSpeed }.maxOrNull(),
        )
    }
}

/** Lowercase-first camel name, matching the Swift raw values (e.g. `leftShoulder`, `trophy`). */
internal fun camel(name: String) = name.lowercase().split('_').mapIndexed { i, part -> if (i == 0) part else part.replaceFirstChar { it.uppercase() } }.joinToString("")
val Joint.key: String get() = camel(name)
val Phase.key: String get() = camel(name)

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
