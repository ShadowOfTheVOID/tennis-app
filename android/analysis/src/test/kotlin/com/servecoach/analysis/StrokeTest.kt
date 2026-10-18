package com.servecoach.analysis

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Same synthetic side-on swings as the Swift StrokeTests: a right-hander facing right.

typealias Keys = Map<Joint, Pair<Double, Double>>

/** Standing body: shoulders y=160, hips y=300 (torso 140 px), athletic stance. */
val stance: Keys = mapOf(
    Joint.NOSE to (305.0 to 100.0),
    Joint.LEFT_SHOULDER to (320.0 to 160.0), Joint.RIGHT_SHOULDER to (280.0 to 160.0),
    Joint.LEFT_HIP to (315.0 to 300.0), Joint.RIGHT_HIP to (285.0 to 300.0),
    Joint.LEFT_KNEE to (367.0 to 370.0), Joint.RIGHT_KNEE to (287.0 to 370.0),
    Joint.LEFT_ANKLE to (360.0 to 440.0), Joint.RIGHT_ANKLE to (230.0 to 440.0),
    Joint.LEFT_ELBOW to (320.0 to 230.0), Joint.LEFT_WRIST to (330.0 to 260.0),
    Joint.RIGHT_ELBOW to (290.0 to 230.0), Joint.RIGHT_WRIST to (300.0 to 260.0),
)

/** Linearly interpolate joint positions between keyframes, sampled at [fps]. */
fun sequence(keys: List<Pair<Double, Keys>>, fps: Double = 15.0, until: Double): List<Frame> {
    val n = floor(until * fps + 1e-9).toInt()
    return (0..n).map { i ->
        val t = i * (1 / fps)
        val after = keys.indexOfFirst { it.first >= t }.let { if (it < 0) keys.size - 1 else it }
        val before = max(0, after - 1)
        val (t0, a) = keys[before]
        val (t1, b) = keys[after]
        val u = if (t1 > t0) min(1.0, max(0.0, (t - t0) / (t1 - t0))) else 1.0
        val joints = Joint.entries.associateWith { j ->
            val p = (stance + a).getValue(j)
            val q = (stance + b).getValue(j)
            Point(p.first + (q.first - p.first) * u, p.second + (q.second - p.second) * u, 0.9)
        }
        Frame(t, Pose(joints))
    }
}

/** Elbow placed to give a fairly straight arm between shoulder and wrist. */
fun arm(shoulder: Pair<Double, Double>, wrist: Pair<Double, Double>, bend: Double = 10.0) =
    (shoulder.first + wrist.first) / 2 to (shoulder.second + wrist.second) / 2 + bend

/** A forehand or backhand: take-back, fast forward swing to contact at [c] seconds, high finish. */
fun groundstroke(backhand: Boolean = false, twoHanded: Boolean = false, c: Double = 1.0, shift: Double = 0.0): List<Pair<Double, Keys>> {
    val hs = if (backhand) (320 + shift) to 160.0 else (280 + shift) to 160.0
    val ns = if (backhand) (280 + shift) to 160.0 else (320 + shift) to 160.0
    fun keys(wrist: Pair<Double, Double>, offArm: Pair<Double, Double>): Keys {
        val k = stance.filterKeys { it !in setOf(Joint.RIGHT_SHOULDER, Joint.LEFT_SHOULDER, Joint.RIGHT_WRIST, Joint.RIGHT_ELBOW) }
            .mapValues { (_, v) -> (v.first + shift) to v.second }.toMutableMap()
        k[Joint.RIGHT_SHOULDER] = hs
        k[Joint.LEFT_SHOULDER] = ns
        k[Joint.RIGHT_WRIST] = wrist
        k[Joint.RIGHT_ELBOW] = arm(hs, wrist)
        val off = if (twoHanded) (wrist.first + 10) to (wrist.second + 10) else offArm
        k[Joint.LEFT_WRIST] = off
        k[Joint.LEFT_ELBOW] = arm(ns, off)
        return k
    }
    return listOf(
        c - 1.0 to keys((300 + shift) to 260.0, (330 + shift) to 260.0),
        c - 0.5 to keys((300 + shift) to 260.0, (330 + shift) to 260.0),
        c - 0.15 to keys((180 + shift) to 200.0, (360 + shift) to 200.0),
        c to keys((360 + shift) to 230.0, (290 + shift) to 260.0),
        c + 0.3 to keys((330 + shift) to 120.0, (290 + shift) to 260.0),
        c + 1.0 to keys((330 + shift) to 120.0, (290 + shift) to 260.0),
    )
}

class StrokeTest {
    private fun StrokeResult.status(id: String) = checks.firstOrNull { it.id == id }?.status

    @Test fun findsOneSwingPerStroke() {
        val swings = StrokeAnalyzer.swings(sequence(groundstroke() + groundstroke(c = 3.5), until = 4.5), Handedness.RIGHT)
        assertEquals(2, swings.size)
        assertTrue(abs(swings[0].time - 1.0) <= 0.1)
        assertTrue(abs(swings[1].time - 3.5) <= 0.1)
    }

    @Test fun standingStillHasNoSwings() =
        assertTrue(StrokeAnalyzer.swings(sequence(listOf(0.0 to emptyMap(), 3.0 to emptyMap()), until = 3.0), Handedness.RIGHT).isEmpty())

    @Test fun goodForehand() {
        val r = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(groundstroke(), until = 2.0), hand = Handedness.RIGHT))
        assertEquals(StrokeType.FOREHAND, r.type)
        assertEquals(listOf(Phase.PREPARATION, Phase.CONTACT, Phase.FINISH), r.keyFrames.map { it.phase })
        assertTrue(r.checks.all { it.status == Status.GOOD }, r.checks.toString())
        assertEquals(100, r.score)
    }

    @Test fun backhandsOneAndTwoHanded() {
        val one = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand = true), until = 2.0), hand = Handedness.RIGHT))
        assertEquals(StrokeType.BACKHAND, one.type)
        assertFalse(one.twoHanded)
        assertNotNull(one.status("contact-spacing"))

        val two = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand = true, twoHanded = true), until = 2.0), hand = Handedness.RIGHT))
        assertEquals(StrokeType.BACKHAND, two.type)
        assertTrue(two.twoHanded)
        assertEquals("Two-handed backhand", two.title)
        assertNull(two.status("contact-spacing"))
    }

    @Test fun lateContactIsFlagged() {
        val keys = groundstroke().toMutableList()
        keys[3] = keys[3].first to keys[3].second + mapOf(Joint.RIGHT_WRIST to (290.0 to 230.0), Joint.RIGHT_ELBOW to arm(280.0 to 160.0, 290.0 to 230.0))
        val r = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(keys, until = 2.0), StrokeType.FOREHAND, Handedness.RIGHT))
        assertNotEquals(Status.GOOD, r.status("contact-in-front"))
    }

    @Test fun volley() {
        fun k(w: Pair<Double, Double>): Keys = mapOf(Joint.RIGHT_WRIST to w, Joint.RIGHT_ELBOW to arm(280.0 to 160.0, w, bend = 25.0))
        val keys = listOf(0.0 to k(300.0 to 220.0), 0.7 to k(270.0 to 210.0), 0.9 to k(270.0 to 210.0), 1.0 to k(370.0 to 215.0), 1.4 to k(370.0 to 215.0), 2.0 to k(370.0 to 215.0))
        val r = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(keys, until = 2.0), hand = Handedness.RIGHT))
        assertEquals(StrokeType.VOLLEY, r.type)
        assertEquals(Status.GOOD, r.status("volley-compact"))
        assertEquals(Status.GOOD, r.status("volley-short"))
    }

    @Test fun serveAndOverheadAreTellApart() {
        val trophy: Keys = mapOf(
            Joint.LEFT_SHOULDER to (320.0 to 150.0), Joint.LEFT_ELBOW to (330.0 to 80.0), Joint.LEFT_WRIST to (340.0 to 10.0),
            Joint.RIGHT_SHOULDER to (280.0 to 175.0), Joint.RIGHT_ELBOW to (220.0 to 170.0), Joint.RIGHT_WRIST to (220.0 to 110.0),
        )
        val contact: Keys = mapOf(Joint.RIGHT_SHOULDER to (285.0 to 150.0), Joint.RIGHT_ELBOW to (295.0 to 55.0), Joint.RIGHT_WRIST to (305.0 to -40.0),
            Joint.LEFT_WRIST to (310.0 to 220.0), Joint.LEFT_ELBOW to (320.0 to 200.0))
        val serve = sequence(listOf(0.0 to emptyMap(), 0.6 to trophy, 0.9 to trophy, 1.0 to contact, 1.6 to emptyMap()), until = 2.0)
        assertEquals(StrokeType.SERVE, StrokeAnalyzer.analyzeClip(serve, hand = Handedness.RIGHT)?.type)

        fun moving(dx: Double, k: Keys): Keys = (stance + k).mapValues { (_, v) -> (v.first + dx) to v.second }
        val noToss = trophy + mapOf(Joint.LEFT_WRIST to (330.0 to 240.0), Joint.LEFT_ELBOW to (325.0 to 200.0))
        val overhead = sequence(listOf(0.0 to moving(-150.0, emptyMap()), 0.5 to moving(-60.0, noToss), 0.9 to moving(0.0, noToss),
            1.0 to moving(0.0, contact), 1.6 to moving(0.0, emptyMap())), until = 2.0)
        val r = assertNotNull(StrokeAnalyzer.analyzeClip(overhead, hand = Handedness.RIGHT))
        assertEquals(StrokeType.OVERHEAD, r.type)
        assertEquals(listOf(Phase.PREPARATION, Phase.CONTACT), r.keyFrames.map { it.phase })
    }

    @Test fun readyPosition() {
        val good = sequence(listOf(0.0 to mapOf(Joint.LEFT_WRIST to (330.0 to 250.0), Joint.RIGHT_WRIST to (300.0 to 250.0))), until = 0.0)[0].pose
        assertEquals(100, StrokeAnalyzer.readyPosition(good).score)
        val lazy = sequence(listOf(0.0 to mapOf(
            Joint.LEFT_KNEE to (315.0 to 370.0), Joint.RIGHT_KNEE to (285.0 to 370.0), Joint.LEFT_ANKLE to (315.0 to 440.0), Joint.RIGHT_ANKLE to (285.0 to 440.0),
            Joint.LEFT_WRIST to (320.0 to 330.0), Joint.RIGHT_WRIST to (290.0 to 330.0),
        )), until = 0.0)[0].pose
        val e = StrokeAnalyzer.readyPosition(lazy)
        assertTrue(e.checks.all { it.status == Status.BAD }, e.checks.toString())
    }

    @Test fun serveResultBridgesToStroke() {
        val s = ServeResult(null, null, null, null).stroke
        assertEquals(StrokeType.SERVE, s.type)
        assertNull(s.score)
    }
}
