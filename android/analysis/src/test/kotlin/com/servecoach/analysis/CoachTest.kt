package com.servecoach.analysis

import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CoachTest {
    private fun pose(vararg overrides: Pair<Joint, Pair<Double, Double>>): Pose {
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

    private fun badTrophyServe(): ServeResult {
        val trophy = pose(
            Joint.LEFT_ELBOW to (340.0 to 80.0), Joint.LEFT_WRIST to (350.0 to 10.0),
            Joint.RIGHT_ELBOW to (250.0 to 230.0), Joint.RIGHT_WRIST to (240.0 to 300.0),
        )
        val contact = pose(
            Joint.RIGHT_SHOULDER to (275.0 to 150.0), Joint.RIGHT_ELBOW to (285.0 to 55.0), Joint.RIGHT_WRIST to (295.0 to -40.0),
            Joint.LEFT_ELBOW to (340.0 to 190.0), Joint.LEFT_WRIST to (310.0 to 200.0),
        )
        return ServeAnalyzer.analyze(listOf(Frame(0.0, trophy), Frame(1.0, contact)), Handedness.RIGHT)
    }

    @Test fun ruleBasedPlanPrioritisesFailures() {
        val report = Coach.ruleBased(badTrophyServe(), Handedness.RIGHT)
        assertEquals(CoachSource.RULES, report.source)
        assertTrue(report.improvements.size in 1..3)
        assertEquals("Hitting elbow ~90°", report.improvements.first().title)
        assertTrue(report.strengths.isNotEmpty())
    }

    @Test fun promptListsChecksAndDrills() {
        val prompt = Coach.prompt(badTrophyServe(), Handedness.RIGHT, hasImages = true)
        assertTrue("[hit-elbow-bend]" in prompt)
        assertTrue("target 70–115°" in prompt)
        assertTrue("The images show the serve in order: trophy position, contact." in prompt)
        assertTrue("Suggested drills" in prompt)
    }

    @Test fun schemaIsValidJson() {
        Json.parseToJsonElement(Coach.schema)
    }

    @Test fun parsesModelReplyAndDropsUnknownChecks() {
        val reply = """
            Here you go:
            ```json
            {"summary":"Good base.","measurement_review":[{"check_id":"id knee-bend","trustworthy":false,"note":"Legs blurry."},
            {"check_id":"made-up","trustworthy":true,"note":"x"}],"strengths":["Tall at contact"],
            "improvements":[{"title":"Elbow up","why":"Power","how":"Lift the elbow","drill":"Mirror work"},
            {"title":"A","why":"b","how":"c","drill":"d"},{"title":"B","why":"b","how":"c","drill":"d"},
            {"title":"C","why":"b","how":"c","drill":"d"}],"next_session_focus":"Elbow height"}
            ```
        """.trimIndent()
        val report = assertNotNull(Coach.parse(reply, badTrophyServe(), Handedness.RIGHT, "Test"))
        assertEquals(CoachSource.ON_DEVICE_AI, report.source)
        assertEquals(listOf("knee-bend"), report.measurementReview.map { it.checkId })
        assertEquals(setOf("knee-bend"), report.distrustedChecks)
        assertEquals(3, report.improvements.size)
        assertEquals("Test", report.modelName)
    }

    @Test fun lowConfidenceChecksAreAlwaysFlagged() {
        val trophy = pose(
            Joint.LEFT_ELBOW to (340.0 to 80.0), Joint.LEFT_WRIST to (350.0 to 10.0),
            Joint.RIGHT_ELBOW to (250.0 to 230.0), Joint.RIGHT_WRIST to (240.0 to 300.0),
        ).let { p -> Pose(p.joints.mapValues { (j, v) -> if (j == Joint.LEFT_KNEE || j == Joint.RIGHT_KNEE) v.copy(confidence = 0.35) else v }) }
        val contact = pose(
            Joint.RIGHT_SHOULDER to (275.0 to 150.0), Joint.RIGHT_ELBOW to (285.0 to 55.0), Joint.RIGHT_WRIST to (295.0 to -40.0),
            Joint.LEFT_ELBOW to (340.0 to 190.0), Joint.LEFT_WRIST to (310.0 to 200.0),
        )
        val serve = ServeAnalyzer.analyze(listOf(Frame(0.0, trophy), Frame(1.0, contact)), Handedness.RIGHT)
        assertEquals(setOf("knee-bend"), Coach.ruleBased(serve, Handedness.RIGHT).distrustedChecks)

        val reply = """{"summary":"Work on the elbow and knees.","measurement_review":[{"check_id":"knee_bend","trustworthy":true,"note":"Fine."},
            {"check_id":"hit_elbow_bend","trustworthy":false,"note":"Arm hidden."}],"strengths":["Good toss"],
            "improvements":[{"title":"Elbow","why":"Power.","how":"Make an L. Drill: hold it for 3 seconds.","drill":"Hold the L."}],"next_session_focus":"Elbow"}"""
        val report = assertNotNull(Coach.parse(reply, serve, Handedness.RIGHT, "Test"))
        assertEquals(setOf("knee-bend", "hit-elbow-bend"), report.distrustedChecks)
        assertEquals("Make an L.", report.improvements.first().how)
    }

    @Test fun rejectsGarbage() {
        assertNull(Coach.parse("I can't help with that.", badTrophyServe(), Handedness.RIGHT, "Test"))
        assertNull(Coach.parse("""{"summary": "", "improvements": []}""", badTrophyServe(), Handedness.RIGHT, "Test"))
    }

    @Test fun confidenceLabelsUseTheCheckedJoints() {
        val joints = pose().joints.mapValues { (j, p) -> if (j == Joint.LEFT_KNEE) p.copy(confidence = 0.35) else p }
        val p = Pose(joints)
        assertEquals("low", Coach.confidenceLabel(p, "knee-bend", Handedness.RIGHT))
        assertEquals("high", Coach.confidenceLabel(p, "hit-elbow-bend", Handedness.RIGHT))
    }

    @Test fun fillsBlankFieldsFromThePlanAndStripsCuePrefix() {
        val reply = """{"summary":"Nice work overall on this serve.","measurement_review":[{"check_id":"[knee-bend]","trustworthy":false,"note":"Low confidence."}],
            "strengths":[],"improvements":[{"title":"Elbow","why":"","how":"Cue: Make an L.","drill":""}],"next_session_focus":""}"""
        val report = assertNotNull(Coach.parse(reply, badTrophyServe(), Handedness.RIGHT, "Test"))
        val first = report.improvements.single()
        assertEquals("Make an L.", first.how)
        assertEquals(Coach.ruleBased(badTrophyServe(), Handedness.RIGHT).improvements.first().drill, first.drill)
        assertEquals(setOf("knee-bend"), report.distrustedChecks)
    }

    @Test fun rejectsJsonStuffedIntoSummary() {
        assertNull(Coach.parse("""{"summary":"{\"Player\": \"x\"}","improvements":[]}""", badTrophyServe(), Handedness.RIGHT, "Test"))
    }
}
