package com.servecoach.analysis

import kotlinx.serialization.json.Json
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PracticeTest {
    private val now = 1_800_000_000_000L
    private val day = 86_400_000L

    /** A forehand record from [daysAgo], with contact out in front good or late. */
    private fun forehand(daysAgo: Long, late: Boolean): PracticeRecord {
        val keys = groundstroke().toMutableList()
        if (late) keys[3] = keys[3].first to keys[3].second + mapOf(Joint.RIGHT_WRIST to (290.0 to 230.0), Joint.RIGHT_ELBOW to arm(280.0 to 160.0, 290.0 to 230.0))
        val stroke = StrokeAnalyzer.analyzeClip(sequence(keys, until = 2.0), StrokeType.FOREHAND, Handedness.RIGHT)!!
        return PracticeRecord.of(stroke, Handedness.RIGHT, date = now - daysAgo * day)
    }

    @Test fun strokeRecordKeepsSpeedChecksAndPoses() {
        val record = forehand(0, late = false)
        assertTrue(assertNotNull(record.swingSpeed) > 3)
        assertEquals(1.0, record.direction)
        assertTrue(record.checks.any { it.id == "contact-in-front" && it.status == "good" })
        assertEquals(13, record.pose(Phase.CONTACT)?.joints?.size)
        assertTrue("leftShoulder" in record.keyPoses.getValue("contact"))

        val json = Json { ignoreUnknownKeys = true }
        assertEquals(record, json.decodeFromString<PracticeRecord>(json.encodeToString(record)))
        val old = """{"id":"x","date":1,"kind":"serve","score":70,"detail":"","topFix":null,"handedness":"right"}"""
        assertTrue(json.decodeFromString<PracticeRecord>(old).checks.isEmpty())
    }

    @Test fun progressShowsImprovementOverWeeks() {
        val records = List(3) { forehand(1, late = false) } + List(3) { forehand(22, late = true) }
        val contact = assertNotNull(PracticeStats.progress(records, "forehand", now).firstOrNull { it.id == "contact-in-front" })
        assertEquals(listOf(3, 0), contact.weeks.map { it.weeksAgo })
        assertEquals("0% good → 100% in 3 weeks", contact.summary)
        assertEquals(100, contact.change)
    }

    @Test fun planFocusesOnMostMissedCheck() {
        val plan = PracticePlan.make(List(4) { forehand(2, late = true) }, now)
        assertEquals("contact-in-front", plan.focus.first().checkId)
        assertEquals(7, plan.days.size)
        assertTrue(plan.days[0].items.any { "Drop-feed balls" in it })
        val empty = PracticePlan.make(emptyList(), now)
        assertTrue(empty.focus.isEmpty())
        assertEquals("Get a baseline", empty.days.first().title)
    }

    @Test fun rhythmAndBest() {
        fun serve(tempo: Double, score: Int) = PracticeRecord(kind = "serve", score = score, detail = "", topFix = null, handedness = "right",
            tempo = tempo, keyPoses = mapOf("contact" to mapOf("nose" to listOf(1.0, 2.0, 0.9))))
        val steady = assertNotNull(PracticeStats.rhythm(listOf(0.50, 0.52, 0.48).map { serve(it, 70) }))
        assertTrue(abs(steady.average - 0.5) < 1e-9)
        assertEquals("Very consistent rhythm", steady.verdict)
        assertEquals("Your rhythm varies a lot", PracticeStats.rhythm(listOf(0.3, 0.6, 0.9).map { serve(it, 70) })?.verdict)
        assertNull(PracticeStats.rhythm(listOf(serve(0.5, 70))))
        assertEquals(90, PracticeStats.best(listOf(serve(0.5, 60), serve(0.5, 90), serve(0.5, 75)), "serve")?.score)
    }

    @Test fun ghostAlignsAndMirrors() {
        val target = sequence(listOf(0.0 to emptyMap()), until = 0.0)[0].pose
        val ghost = Pose(target.joints.mapValues { (_, p) -> Point(1000 - 2 * p.x, 2 * p.y + 50, p.confidence) })
        val aligned = assertNotNull(PoseAlignment.align(ghost, -1.0, target, 1.0))
        for ((joint, p) in target.joints) {
            assertTrue(abs(aligned.joints.getValue(joint).x - p.x) < 1e-6)
            assertTrue(abs(aligned.joints.getValue(joint).y - p.y) < 1e-6)
        }
    }

    @Test fun serveTempoAndFacing() {
        val trophy = Pose(mapOf(
            Joint.NOSE to (300.0 to 100.0), Joint.LEFT_SHOULDER to (330.0 to 150.0), Joint.LEFT_ELBOW to (340.0 to 80.0), Joint.LEFT_WRIST to (350.0 to 10.0),
            Joint.RIGHT_SHOULDER to (270.0 to 175.0), Joint.RIGHT_ELBOW to (210.0 to 170.0), Joint.RIGHT_WRIST to (210.0 to 110.0),
            Joint.LEFT_HIP to (320.0 to 300.0), Joint.RIGHT_HIP to (280.0 to 300.0),
        ).mapValues { (_, v) -> Point(v.first, v.second, 0.9) })
        val contact = Pose(trophy.joints + mapOf(Joint.RIGHT_SHOULDER to Point(275.0, 150.0, 0.9), Joint.RIGHT_ELBOW to Point(285.0, 55.0, 0.9),
            Joint.RIGHT_WRIST to Point(295.0, -40.0, 0.9), Joint.LEFT_WRIST to Point(310.0, 200.0, 0.9), Joint.LEFT_ELBOW to Point(340.0, 190.0, 0.9)))
        val serve = ServeAnalyzer.analyze(listOf(Frame(0.5, trophy), Frame(1.1, contact)), Handedness.RIGHT).stroke
        assertTrue(abs(assertNotNull(serve.tempo) - 0.6) < 1e-9)
        assertEquals(1.0, serve.direction)
    }

    @Test fun shareClipTimelineAndCaptions() {
        val frames = ShareClip.frames(listOf(0.0, 0.1, 0.2))
        assertEquals(25 + 45, frames.size) // 0.2 s at quarter speed, 30 fps, plus a 1.5 s hold
        assertEquals(listOf(0, 1, 2, 2), listOf(frames[0], frames[12], frames[24], frames.last()))
        assertTrue(ShareClip.frames(emptyList()).isEmpty())

        val stroke = StrokeAnalyzer.analyzeClip(sequence(groundstroke(), until = 2.0), StrokeType.FOREHAND, Handedness.RIGHT)!!
        assertTrue(ShareClip.title(stroke).startsWith("Forehand · "))
        val first = stroke.keyFrames.minOf { it.frame.time }
        assertEquals(null, ShareClip.caption(stroke, first - 0.5))
        assertTrue(assertNotNull(ShareClip.caption(stroke, stroke.frame(Phase.CONTACT)!!.time)).startsWith("Contact"))
    }
}
