package com.servecoach.analysis

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BallTest {
    private val w = 160
    private val h = 120

    /** A court-green frame with a still yellow sign and, optionally, a ball at ([bx], [by]). */
    private fun frame(time: Double, bx: Double?, by: Double?): RgbImage {
        val rgb = ByteArray(w * h * 3)
        fun set(x: Int, y: Int, r: Int, g: Int, b: Int) {
            if (x !in 0 until w || y !in 0 until h) return
            val i = 3 * (y * w + x)
            rgb[i] = r.toByte(); rgb[i + 1] = g.toByte(); rgb[i + 2] = b.toByte()
        }
        for (y in 0 until h) for (x in 0 until w) set(x, y, 60, 140, 70)
        for (y in 20 until 24) for (x in 20 until 24) set(x, y, 220, 230, 40)
        if (bx != null && by != null) {
            for (y in -3..3) for (x in -3..3) if (x * x + y * y <= 5) set((bx + x).toInt(), (by + y).toInt(), 210, 235, 50)
        }
        return RgbImage(w, h, rgb, time)
    }

    @Test fun ballColour() {
        assertTrue(BallDetector.isBallColour(204, 255, 0))
        assertTrue(BallDetector.isBallColour(210, 235, 50))
        assertFalse(BallDetector.isBallColour(60, 140, 70)) // court green
        assertFalse(BallDetector.isBallColour(224, 172, 105)) // skin
        assertFalse(BallDetector.isBallColour(240, 240, 240)) // white line
        assertFalse(BallDetector.isBallColour(190, 90, 50)) // clay
    }

    @Test fun tracksMovingBallAndIgnoresStillYellow() {
        val tracker = BallTracker()
        for (i in 0 until 12) tracker.add(frame(i / 30.0, 30.0 + 8 * i, 90.0 - 4 * i))
        val seen = tracker.sightings
        assertTrue(seen.size >= 9, "saw ${seen.size}")
        for (s in seen) {
            val i = (s.time * 30).let { kotlin.math.round(it).toInt() }
            assertTrue(abs(s.x * w - (30.0 + 8 * i + 0.5)) < 1.5 && abs(s.y * h - (90.0 - 4 * i + 0.5)) < 1.5, "off at $i: $s")
        }
        // Nothing reported near the still sign.
        assertTrue(seen.none { abs(s(it.x) - 22) < 4 && abs(it.y * h - 22) < 4 })
    }

    private fun s(x: Double) = x * w

    @Test fun ballAppearingOnlyOnceIsNotReported() {
        val tracker = BallTracker()
        tracker.add(frame(0.0, null, null))
        assertNull(tracker.add(frame(1 / 30.0, 80.0, 60.0)))
        tracker.add(frame(2 / 30.0, null, null))
        tracker.add(frame(3 / 30.0, null, null))
        assertTrue(tracker.sightings.isEmpty())
    }

    @Test fun ralliesCountDirectionChanges() {
        // Back and forth across the frame: right, left, right = 3 shots, then a 3 s break and a 2-shot rally.
        val xs = listOf(0.2, 0.4, 0.6, 0.8, 0.6, 0.4, 0.2, 0.4, 0.6, 0.8)
        val first = xs.mapIndexed { i, x -> BallSighting(i * 0.1, x, 0.5) }
        val second = listOf(0.8, 0.5, 0.2, 0.5, 0.8).mapIndexed { i, x -> BallSighting(4.0 + i * 0.1, x, 0.5) }
        val rallies = BallAnalysis.rallies(first + second)
        assertEquals(listOf(3, 2), rallies.map { it.shots })
        // Small wobbles aren't shots.
        assertTrue(BallAnalysis.rallies(listOf(0.5, 0.55, 0.5, 0.55).mapIndexed { i, x -> BallSighting(i * 0.1, x, 0.5) }).isEmpty())
    }

    @Test fun tossPlacementAndConsistency() {
        val serve = ServeAnalyzer.analyze(listOf(Frame(0.5, goodTrophy), Frame(1.1, goodContact)), Handedness.RIGHT).stroke
        val torso = goodTrophy.torsoLength!!
        val nose = goodTrophy[Joint.NOSE]!!
        val shoulder = goodTrophy[Joint.RIGHT_SHOULDER]!!
        val size = 1000.0
        val apexX = (shoulder.x + 0.5 * torso * serve.direction) / size
        val apexY = (nose.y - 1.2 * torso) / size
        val balls = listOf(BallSighting(0.3, apexX, apexY + 0.1), BallSighting(0.6, apexX, apexY), BallSighting(0.9, apexX, apexY + 0.05))
        val toss = assertNotNull(BallAnalysis.toss(balls, serve, Handedness.RIGHT, size, size))
        assertTrue(abs(toss.height - 1.2) < 1e-6 && abs(toss.forward - 0.5) < 1e-6, "$toss")
        assertTrue(toss.tip.startsWith("Good toss"))
        assertTrue(TossReading(1.2, -0.3).tip.contains("behind"))

        val c = assertNotNull(BallAnalysis.consistency(listOf(TossReading(1.2, 0.5), TossReading(1.3, 0.5), TossReading(1.1, 0.5))))
        assertEquals("Very consistent toss", c.verdict)
        assertNull(BallAnalysis.consistency(listOf(toss)))
    }
}
