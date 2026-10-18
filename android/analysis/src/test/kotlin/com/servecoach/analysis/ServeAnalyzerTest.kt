package com.servecoach.analysis

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Same fixtures as the Swift ServeAnalyzerTests, so both platforms grade poses identically.

/** Build a pose in pixel space; unspecified joints get a neutral standing position. */
private fun makePose(overrides: Map<Joint, Pair<Double, Double>> = emptyMap()): Pose {
    val base = mapOf(
        Joint.NOSE to (300.0 to 100.0),
        Joint.LEFT_SHOULDER to (330.0 to 160.0), Joint.RIGHT_SHOULDER to (270.0 to 160.0),
        Joint.LEFT_ELBOW to (340.0 to 220.0), Joint.RIGHT_ELBOW to (260.0 to 220.0),
        Joint.LEFT_WRIST to (345.0 to 280.0), Joint.RIGHT_WRIST to (255.0 to 280.0),
        Joint.LEFT_HIP to (320.0 to 300.0), Joint.RIGHT_HIP to (280.0 to 300.0),
        Joint.LEFT_KNEE to (320.0 to 370.0), Joint.RIGHT_KNEE to (280.0 to 370.0),
        Joint.LEFT_ANKLE to (320.0 to 440.0), Joint.RIGHT_ANKLE to (280.0 to 440.0),
    )
    return Pose((base + overrides).mapValues { (_, p) -> Point(p.first, p.second, 0.9) })
}

internal val goodTrophy = makePose(mapOf(
    Joint.LEFT_SHOULDER to (330.0 to 150.0), Joint.LEFT_ELBOW to (340.0 to 80.0), Joint.LEFT_WRIST to (350.0 to 10.0),
    Joint.RIGHT_SHOULDER to (270.0 to 175.0), Joint.RIGHT_ELBOW to (210.0 to 170.0), Joint.RIGHT_WRIST to (210.0 to 110.0),
    Joint.LEFT_KNEE to (340.0 to 370.0), Joint.RIGHT_KNEE to (300.0 to 370.0),
))

internal val goodContact = makePose(mapOf(
    Joint.RIGHT_SHOULDER to (275.0 to 150.0), Joint.RIGHT_ELBOW to (285.0 to 55.0), Joint.RIGHT_WRIST to (295.0 to -40.0),
    Joint.LEFT_ELBOW to (340.0 to 190.0), Joint.LEFT_WRIST to (310.0 to 200.0),
))

private fun Evaluation.status(id: String) = checks.first { it.id == id }.status

/** Mirror a pose horizontally and swap left/right joints (a right-hander becomes a left-hander). */
private fun mirrored(pose: Pose) = Pose(pose.joints.entries.associate { (joint, p) ->
    val name = joint.name
    val swapped = when {
        name.startsWith("LEFT_") -> Joint.valueOf("RIGHT_" + name.removePrefix("LEFT_"))
        name.startsWith("RIGHT_") -> Joint.valueOf("LEFT_" + name.removePrefix("RIGHT_"))
        else -> joint
    }
    swapped to p.copy(x = 600 - p.x)
})

class GeometryTest {
    @Test fun rightAngle() = assertEquals(90.0, Geometry.angle(Point(1.0, 0.0), Point(0.0, 0.0), Point(0.0, 1.0)), 1e-9)
    @Test fun straightLine() = assertEquals(180.0, Geometry.angle(Point(-1.0, 0.0), Point(0.0, 0.0), Point(1.0, 0.0)), 1e-9)
}

class ServeAnalyzerTest {
    @Test fun phaseDetection() {
        assertEquals(Phase.TROPHY, ServeAnalyzer.phase(goodTrophy, Handedness.RIGHT))
        assertEquals(Phase.CONTACT, ServeAnalyzer.phase(goodContact, Handedness.RIGHT))
        assertEquals(Phase.READY, ServeAnalyzer.phase(makePose(), Handedness.RIGHT))
    }

    @Test fun textbookTrophyScoresFull() {
        val e = ServeAnalyzer.trophy(goodTrophy, Handedness.RIGHT)
        assertTrue(e.checks.all { it.status == Status.GOOD }, e.checks.toString())
        assertEquals(100, e.score)
    }

    @Test fun leftHanderMirrorScoresFull() =
        assertEquals(100, ServeAnalyzer.trophy(mirrored(goodTrophy), Handedness.LEFT).score)

    @Test fun flagsStraightHittingArmAndLowElbow() {
        val pose = makePose(mapOf(
            Joint.LEFT_ELBOW to (340.0 to 80.0), Joint.LEFT_WRIST to (350.0 to 10.0),
            Joint.RIGHT_ELBOW to (250.0 to 230.0), Joint.RIGHT_WRIST to (240.0 to 300.0),
        ))
        val e = ServeAnalyzer.trophy(pose, Handedness.RIGHT)
        assertEquals(Status.BAD, e.status("hit-elbow-bend"))
        assertEquals(Status.BAD, e.status("hit-elbow-height"))
    }

    @Test fun flagsLockedKnees() {
        val e = ServeAnalyzer.trophy(makePose(mapOf(Joint.LEFT_WRIST to (350.0 to 10.0))), Handedness.RIGHT)
        assertEquals(Status.BAD, e.status("knee-bend"))
    }

    @Test fun hiddenLegsAreUnknownAndExcludedFromScore() {
        val hidden = setOf(Joint.LEFT_KNEE, Joint.RIGHT_KNEE, Joint.LEFT_ANKLE, Joint.RIGHT_ANKLE)
        val pose = Pose(goodTrophy.joints.mapValues { (j, p) -> if (j in hidden) p.copy(confidence = 0.1) else p })
        val e = ServeAnalyzer.trophy(pose, Handedness.RIGHT)
        assertEquals(Status.UNKNOWN, e.status("knee-bend"))
        assertEquals(100, e.score)
    }

    @Test fun fullExtensionContact() {
        val e = ServeAnalyzer.contact(goodContact, Handedness.RIGHT)
        assertTrue(e.checks.all { it.status == Status.GOOD }, e.checks.toString())
    }

    @Test fun flagsBentArmAtContact() {
        val e = ServeAnalyzer.contact(makePose(mapOf(Joint.RIGHT_ELBOW to (250.0 to 90.0), Joint.RIGHT_WRIST to (300.0 to 40.0))), Handedness.RIGHT)
        assertEquals(Status.BAD, e.status("hit-arm-extended"))
    }

    @Test fun keyFramesTrophyBeforeContact() {
        val frames = listOf(Frame(0.0, makePose()), Frame(0.5, goodTrophy), Frame(1.0, goodContact), Frame(1.5, makePose()))
        val (trophy, contact) = ServeAnalyzer.keyFrames(frames, Handedness.RIGHT)
        assertEquals(0.5, trophy?.time)
        assertEquals(1.0, contact?.time)
    }

    @Test fun trackerReportsServeAfterContact() {
        val tracker = ServeTracker(Handedness.RIGHT)
        assertNull(tracker.add(Frame(0.0, makePose())))
        assertNull(tracker.add(Frame(0.5, goodTrophy)))
        assertNull(tracker.add(Frame(1.0, goodContact)))
        val result = tracker.add(Frame(1.2, makePose()))
        assertEquals(0.5, result?.trophyFrame?.time)
        assertEquals(1.0, result?.contactFrame?.time)
        assertEquals(100, result?.score)
        assertNull(result?.topTip)
        assertNull(tracker.add(Frame(1.4, makePose())))
    }

    @Test fun trackerForgetsFramesOutsideWindow() {
        val tracker = ServeTracker(Handedness.RIGHT, window = 1.0)
        tracker.add(Frame(0.0, goodTrophy))
        tracker.add(Frame(5.0, goodContact))
        val result = tracker.add(Frame(5.2, makePose()))
        assertNull(result?.trophyFrame)
        assertNotNull(result?.contactFrame)
    }
}
