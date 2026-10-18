package com.servecoach.analysis

import kotlinx.serialization.Serializable
import kotlin.math.sqrt

/** One reading from a watch: acceleration in g and rotation rate in radians per second, in the watch's axes. */
data class MotionSample(
    val time: Double,
    val ax: Double, val ay: Double, val az: Double,
    val gx: Double, val gy: Double, val gz: Double,
) {
    val rotation: Double get() = sqrt(gx * gx + gy * gy + gz * gz)
    val acceleration: Double get() = sqrt(ax * ax + ay * ay + az * az)
}

/** One swing felt at the wrist. */
data class WristSwing(val time: Double, /** Peak wrist rotation, degrees per second. */ val peakRotation: Double, /** Peak acceleration, g. */ val peakAcceleration: Double)

/**
 * Finds swings in a watch's motion: a burst of wrist rotation over [threshold] rad/s, ended when it
 * falls below half that, with at least [gap] seconds between swings. Mirrors `WristSwingDetector` in Swift.
 */
class WristSwingDetector(private val threshold: Double = 6.0, private val gap: Double = 0.7) {
    private var inSwing = false
    private var peak = 0.0
    private var peakTime = 0.0
    private var peakAccel = 0.0
    private var lastSwing = Double.NEGATIVE_INFINITY

    fun add(s: MotionSample): WristSwing? {
        val w = s.rotation
        if (!inSwing) {
            if (w < threshold) return null
            inSwing = true
            peak = w; peakTime = s.time; peakAccel = s.acceleration
            return null
        }
        if (w > peak) { peak = w; peakTime = s.time }
        if (s.acceleration > peakAccel) peakAccel = s.acceleration
        if (w >= threshold / 2) return null
        inSwing = false
        if (peakTime - lastSwing < gap) return null
        lastSwing = peakTime
        return WristSwing(peakTime, Math.toDegrees(peak), peakAccel)
    }
}

/** A watch practice session, small enough to send to the phone. Mirrors `WatchSummary` in Swift. */
@Serializable
data class WatchSummary(
    /** Start, in milliseconds since the epoch. */
    val date: Long,
    val seconds: Double,
    val swings: Int,
    /** Fastest and average peak wrist rotation, degrees per second. */
    val best: Double,
    val average: Double,
    /** Spread of the peaks relative to their average (0 = identical swings). */
    val spread: Double,
) {
    val perMinute: Double get() = if (seconds > 0) swings * 60 / seconds else 0.0

    /** Rough racket-head speed for the fastest swing: wrist rotation × about 0.9 m (forearm and racket), in m/s. */
    val racketSpeed: Double get() = Math.toRadians(best) * 0.9

    val verdict: String get() = when {
        swings < 3 -> "Too few swings to judge consistency"
        spread <= 0.15 -> "Very even swing speed"
        spread <= 0.3 -> "Fairly even swing speed"
        else -> "Swing speed varies a lot: aim for the same smooth acceleration every time"
    }

    companion object {
        /** Wear OS message path for a finished session. */
        const val PATH = "/serve-coach/session"

        fun of(swings: List<WristSwing>, seconds: Double, date: Long): WatchSummary {
            val peaks = swings.map { it.peakRotation }
            val average = if (peaks.isEmpty()) 0.0 else peaks.average()
            val spread = if (peaks.size < 2 || average == 0.0) 0.0
                else sqrt(peaks.sumOf { (it - average) * (it - average) } / peaks.size) / average
            return WatchSummary(date, seconds, swings.size, peaks.maxOrNull() ?: 0.0, average, spread)
        }
    }
}
