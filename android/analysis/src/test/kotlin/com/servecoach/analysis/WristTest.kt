package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.round
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WristTest {
    /** 100 Hz wrist motion: three swings (15, 20, 12 rad/s), one with a double peak, and a gentle 4 rad/s wave. */
    private fun samples(): List<MotionSample> {
        val bumps = listOf(1.0 to 15.0, 1.15 to 14.0, 3.0 to 20.0, 5.0 to 12.0, 7.0 to 4.0)
        return (0 until 900).map { i ->
            val t = i / 100.0
            val w = 0.5 + bumps.sumOf { (bt, peak) -> peak * exp(-((t - bt) / 0.04).pow(2)) }
            MotionSample(t, 0.0, 0.0, 1 + w / 10, w * 0.6, w * 0.8, 0.0)
        }
    }

    @Test fun detectsSwingsOnce() {
        val detector = WristSwingDetector()
        val swings = samples().mapNotNull { detector.add(it) }
        assertEquals(listOf(1.0, 3.0, 5.0), swings.map { round(it.time * 10) / 10 })
        assertTrue(abs(swings[1].peakRotation - Math.toDegrees(20.5)) < 1)
        assertTrue(swings[1].peakAcceleration > 2.5)

        val summary = WatchSummary.of(swings, seconds = 600.0, date = 0)
        assertEquals(3, summary.swings)
        assertTrue(abs(summary.perMinute - 0.3) < 1e-9)
        assertTrue(abs(summary.racketSpeed - 20.5 * 0.9) < 0.1)
        assertEquals("Fairly even swing speed", summary.verdict)

        val record = PracticeRecord.of(summary, Handedness.RIGHT)
        assertEquals("Watch session", record.title)
        assertEquals("3 swings in 10 min · fastest ≈ 1,175°/s · Fairly even swing speed", record.detail)
        assertNull(record.score)
    }
}
