package com.servecoach.analysis

import kotlin.math.roundToInt
import kotlin.math.sqrt

// Insights built from practice history: progress per check, serve rhythm, swing speed, the
// weekly practice plan, and lining up a "ghost" of your best stroke. Mirrors Practice.swift.

/** One week's share of a check graded good. */
data class WeekRate(/** 0 = the last 7 days, 1 = the 7 days before that, ... */ val weeksAgo: Int, val goodRate: Double, val count: Int)

/** How one check has gone over recent weeks, oldest week first. */
data class CheckProgress(val id: String, val label: String, val weeks: List<WeekRate>) {
    /** "60% good → 85% in 3 weeks", or just "85% good" with one week of data. */
    val summary: String
        get() {
            val first = weeks.firstOrNull() ?: return "No data yet"
            val last = weeks.last()
            val latest = "${(last.goodRate * 100).roundToInt()}%"
            if (weeks.size == 1) return "$latest good"
            val span = first.weeksAgo - last.weeksAgo
            return "${(first.goodRate * 100).roundToInt()}% good → $latest in $span week${if (span == 1) "" else "s"}"
        }

    /** Change in good rate from the first week to the latest, in percentage points. */
    val change: Int? get() = if (weeks.size < 2) null else ((weeks.last().goodRate - weeks.first().goodRate) * 100).roundToInt()
}

/** How consistent the serve's timing from trophy position to contact is. */
data class RhythmStats(val average: Double, /** Standard deviation of the tempo, in seconds. */ val spread: Double, val count: Int) {
    val verdict: String
        get() = if (spread <= 0.08) "Very consistent rhythm" else if (spread <= 0.15) "Fairly consistent rhythm" else "Your rhythm varies a lot"

    val tip: String
        get() = if (spread <= 0.15) "Keep the same toss and swing tempo on first and second serves."
        else "Inconsistent rhythm often leads to double faults. Say \"toss… hit\" in the same tempo on every serve."
}

object PracticeStats {
    private const val WEEK_MS = 7L * 24 * 3600 * 1000

    /** Weekly good rate for every check of one kind of stroke, worst latest rate first. */
    fun progress(records: List<PracticeRecord>, kind: String, now: Long = System.currentTimeMillis(), weeks: Int = 8): List<CheckProgress> {
        val labels = mutableMapOf<String, String>()
        val tallies = mutableMapOf<String, MutableMap<Int, IntArray>>()
        for (record in records) {
            if (record.kind != kind) continue
            val weeksAgo = ((now - record.date) / WEEK_MS).toInt()
            if (now < record.date || weeksAgo >= weeks) continue
            for (check in record.checks) {
                if (check.status == "unknown") continue
                labels[check.id] = check.label
                val t = tallies.getOrPut(check.id) { mutableMapOf() }.getOrPut(weeksAgo) { IntArray(2) }
                t[1]++
                if (check.status == "good") t[0]++
            }
        }
        return tallies.map { (id, byWeek) ->
            CheckProgress(id, labels[id] ?: id, byWeek.keys.sortedDescending().map { w ->
                val t = byWeek.getValue(w)
                WeekRate(w, t[0].toDouble() / t[1], t[1])
            })
        }.sortedWith(compareBy<CheckProgress> { it.weeks.lastOrNull()?.goodRate ?: 0.0 }.thenBy { it.id })
    }

    /** Serve rhythm over the most recent serves. Null until there are at least 3. */
    fun rhythm(records: List<PracticeRecord>, last: Int = 20): RhythmStats? {
        val tempos = records.filter { it.kind == StrokeType.SERVE.key }.mapNotNull { it.tempo }.take(last)
        if (tempos.size < 3) return null
        val mean = tempos.average()
        val variance = tempos.sumOf { (it - mean) * (it - mean) } / tempos.size
        return RhythmStats(mean, sqrt(variance), tempos.size)
    }

    /** Fastest estimated hand speed per stroke kind, in metres per second. */
    fun topSpeeds(records: List<PracticeRecord>): Map<String, Double> =
        records.filter { it.kind != PracticeRecord.MATCH_KIND && it.swingSpeed != null }
            .groupBy { it.kind }.mapValues { (_, rs) -> rs.maxOf { it.swingSpeed!! } }

    /** The best-scoring saved stroke of [kind] that has poses to compare against (the newest on ties). */
    fun best(records: List<PracticeRecord>, kind: String): PracticeRecord? =
        records.filter { it.kind == kind && it.keyPoses.isNotEmpty() && it.score != null }
            .maxWithOrNull(compareBy<PracticeRecord> { it.score }.thenBy { it.date })
}

object PoseAlignment {
    /**
     * [ghost] moved and scaled so its hips and torso sit on top of [target]'s, and mirrored when the
     * two strokes faced opposite ways. Null if either pose lacks hips and shoulders.
     */
    fun align(ghost: Pose, ghostDirection: Double, target: Pose, targetDirection: Double): Pose? {
        val gHip = StrokeAnalyzer.hipMid(ghost) ?: return null
        val tHip = StrokeAnalyzer.hipMid(target) ?: return null
        val gT = ghost.torsoLength ?: return null
        val tT = target.torsoLength ?: return null
        val scale = tT / gT
        val mirror = if (ghostDirection * targetDirection < 0) -1.0 else 1.0
        return Pose(ghost.joints.mapValues { (_, p) ->
            Point(tHip.x + (p.x - gHip.x) * scale * mirror, tHip.y + (p.y - gHip.y) * scale, p.confidence)
        })
    }
}

/** A week of practice built from your most common fixes. */
data class PracticePlan(val focus: List<Focus>, val days: List<Day>) {
    data class Focus(
        val checkId: String,
        val label: String,
        /** The stroke kind (a [StrokeType.key]). */
        val kind: String,
        /** Share of recent attempts where this check needed work. */
        val missRate: Double,
        val drill: String,
    ) {
        val id: String get() = "$kind/$checkId"
        val strokeTitle: String get() = StrokeType.entries.firstOrNull { it.key == kind }?.title ?: kind
    }

    data class Day(/** 1 to 7. */ val day: Int, val title: String, val items: List<String>)

    companion object {
        /**
         * Build next week's plan from the last 14 days of strokes. Needs at least 3 attempts of a
         * check before it counts; with too little data it returns a getting-started plan.
         */
        fun make(records: List<PracticeRecord>, now: Long = System.currentTimeMillis()): PracticePlan {
            data class Tally(val label: String, val kind: String, var miss: Int = 0, var total: Int = 0)
            val misses = mutableMapOf<String, Tally>()
            for (record in records) {
                if (record.kind == PracticeRecord.MATCH_KIND || now - record.date > 14L * 24 * 3600 * 1000) continue
                for (check in record.checks) {
                    if (check.status == "unknown") continue
                    val m = misses.getOrPut("${record.kind}/${check.id}") { Tally(check.label, record.kind) }
                    m.total++
                    if (check.status != "good") m.miss++
                }
            }
            val focus = misses.mapNotNull { (key, m) ->
                if (m.total < 3 || m.miss == 0) return@mapNotNull null
                val checkId = key.substringAfterLast('/')
                Focus(checkId, m.label, m.kind, m.miss.toDouble() / m.total, Coach.drill(checkId))
            }.sortedWith(compareByDescending<Focus> { it.missRate }.thenBy { it.id }).take(3)

            val first = focus.firstOrNull() ?: return PracticePlan(emptyList(), listOf(
                Day(1, "Get a baseline", listOf("Record 10 serves and 10 forehands on the Live tab.")),
                Day(2, "Backhands and volleys", listOf("Record 10 backhands and 10 volleys.")),
                Day(3, "Play", listOf("Film a practice set and analyze it in Match mode.")),
                Day(4, "Rest", listOf("Rest or stretch. Your personalised plan appears once you've recorded a few strokes.")),
            ))
            fun work(f: Focus) = listOf(
                "${f.strokeTitle}: ${f.label.lowercase()} (needed work ${(f.missRate * 100).roundToInt()}% of the time).",
                "Drill: ${f.drill}",
                "Then hit 20 ${f.strokeTitle.lowercase()}s thinking only about this.",
            )
            val second = focus.getOrElse(1) { first }
            val third = focus.getOrElse(2) { first }
            return PracticePlan(focus, listOf(
                Day(1, "Focus: ${first.label}", work(first)),
                Day(2, "Focus: ${second.label}", work(second)),
                Day(3, "Footwork", listOf("Drill: ${Coach.drill("split-step")}", "Drill: ${Coach.drill("ready-knees")}")),
                Day(4, "Focus: ${third.label}", work(third)),
                Day(5, "Check your progress", work(first) + "Record 5 strokes in the app to see if the score moved."),
                Day(6, "Play", listOf("Play a practice set and film it. Analyze it in Match mode.")),
                Day(7, "Rest", listOf("Rest, stretch your shoulders and hips, and let it sink in.")),
            ))
        }
    }
}
