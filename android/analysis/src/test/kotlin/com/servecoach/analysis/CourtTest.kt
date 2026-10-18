package com.servecoach.analysis

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CourtTest {
    /** A court seen in perspective: the far baseline is shorter and higher in the image. */
    private val taps = listOf(0.2 to 0.8, 0.8 to 0.8, 0.65 to 0.4, 0.35 to 0.4)

    private fun near(a: Pair<Double, Double>?, x: Double, y: Double, tol: Double = 1e-6) =
        a != null && abs(a.first - x) < tol && abs(a.second - y) < tol

    @Test fun calibrationMapsCornersAndCentre() {
        val court = assertNotNull(Court.calibrate(taps))
        taps.zip(Court.corners).forEach { (t, c) -> assertTrue(near(court.map(t.first, t.second), c.first, c.second), "$t") }
        // The diagonals cross at the centre of the court, even in perspective.
        assertTrue(near(court.map(0.5, 0.8 - 0.4 * 2 / 3), Court.WIDTH / 2, Court.NET))
        // A crossed (bow-tie) order is rejected.
        assertNull(Court.calibrate(listOf(taps[0], taps[2], taps[1], taps[3])))
    }

    @Test fun depthAndInOut() {
        assertEquals(Depth.SHORT, Bounce(0.0, 4.0, 15.0).depth)
        assertEquals(Depth.MID, Bounce(0.0, 4.0, 19.5).depth)
        assertEquals(Depth.DEEP, Bounce(0.0, 4.0, 22.0).depth)
        assertTrue(Bounce(0.0, Court.WIDTH + 0.04, 20.0).isIn) // on the line
        assertTrue(Bounce(0.0, 4.0, 24.2).long)
        assertTrue(Bounce(0.0, -0.5, 20.0).wide)
    }

    /** Five sightings around a bounce at image point ([x], [y]) at [t], travelling right. */
    private fun bounceAt(t: Double, x: Double, y: Double) =
        listOf(-0.03, -0.015, 0.0, -0.01, -0.02).mapIndexed { i, dy -> BallSighting(t + (i - 2) / 30.0, x + (i - 2) * 0.005, y + dy) }

    @Test fun findsBouncesButNotHits() {
        assertEquals(1, CourtAnalysis.bounces(bounceAt(1.0, 0.5, 0.6)).size)
        // The same shape with the ball reversing across the frame is a hit, not a bounce.
        val hit = listOf(-0.03, -0.015, 0.0, -0.01, -0.02).mapIndexed { i, dy -> BallSighting(1 + (i - 2) / 30.0, 0.5 - abs(i - 2) * 0.01, 0.6 + dy) }
        assertTrue(CourtAnalysis.bounces(hit).isEmpty())
    }

    @Test fun placementOfYourShots() {
        val court = Court.calibrate(taps)!!
        val toImage = Homography.fit(Court.corners, taps)!!
        val spots = listOf(4.0 to 22.0, 4.0 to 25.0, 9.5 to 18.0, 2.0 to 15.0)
        val sightings = spots.flatMapIndexed { i, (x, y) -> toImage.map(x, y)!!.let { (ix, iy) -> bounceAt(i + 1.0, ix, iy) } }
        val feet = listOf(toImage.map(4.0, 2.0)!!)
        val p = CourtAnalysis.placement(sightings, court, feet)
        assertEquals(4, p.yours.size)
        assertTrue(p.theirs.isEmpty())
        assertEquals(0.5, p.inRate)
        assertEquals(1, p.long)
        assertEquals(1, p.wide)
        assertEquals(0.5, p.depthRate(Depth.DEEP))
        assertTrue(assertNotNull(p.tip).contains("long") || p.tip!!.contains("wide"))
    }
}
