package com.servecoach.analysis

import kotlin.math.floor

/** What a shared clip shows and when: slow motion, then a short hold on the last frame. Mirrors `ShareClip` in Swift. */
object ShareClip {
    const val FPS = 30
    const val SLOWDOWN = 4.0
    /** Seconds to hold the last frame so the scores can be read. */
    const val HOLD = 1.5

    /** For each video frame, the index into [times] (source frame times, oldest first) to show. */
    fun frames(times: List<Double>, fps: Int = FPS, slowdown: Double = SLOWDOWN, hold: Double = HOLD): List<Int> {
        if (times.isEmpty()) return emptyList()
        val first = times.first()
        val count = floor((times.last() - first) * slowdown * fps + 1e-9).toInt() + 1
        val out = ArrayList<Int>()
        var index = 0
        for (i in 0 until count) {
            val t = first + i.toDouble() / fps / slowdown
            while (index + 1 < times.size && times[index + 1] <= t + 1e-9) index++
            out += index
        }
        repeat((hold * fps).toInt()) { out += times.lastIndex }
        return out
    }

    fun title(result: StrokeResult): String = result.score?.let { "${result.title} · $it/100" } ?: result.title

    /** The latest key moment reached by [time], with its score, e.g. "Contact 80". */
    fun caption(result: StrokeResult, time: Double): String? {
        val key = result.keyFrames.filter { it.frame.time <= time + 0.02 }.maxByOrNull { it.frame.time } ?: return null
        val score = result.evaluations.firstOrNull { it.phase == key.phase }?.score
        return if (score == null) key.phase.title else "${key.phase.title} $score"
    }

    fun footer(result: StrokeResult): String = result.topTip?.let { "Work on: ${it.label}" } ?: "Every check passed"
}
