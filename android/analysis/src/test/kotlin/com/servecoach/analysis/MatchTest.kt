package com.servecoach.analysis

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class MatchTest {
    /** Hops the feet up before each shot (a split step) when [split] is set. */
    private fun rally(split: Boolean): List<Pair<Double, Keys>> {
        val keys = mutableListOf<Pair<Double, Keys>>()
        listOf(2.0, 5.0, 8.0).forEachIndexed { i, contact ->
            val strokes = groundstroke(backhand = i == 1, c = contact).toMutableList()
            if (split) {
                val hop: Keys = mapOf(Joint.LEFT_ANKLE to (360.0 to 425.0), Joint.RIGHT_ANKLE to (230.0 to 425.0))
                strokes.add(2, contact - 0.9 to strokes[1].second + hop)
                strokes.add(3, contact - 0.8 to strokes[1].second)
            }
            keys += strokes
        }
        return keys.sortedBy { it.first }
    }

    @Test fun findsEveryStrokeAndSummarises() {
        val report = MatchAnalyzer.analyze(sequence(rally(split = true), until = 9.5), Handedness.RIGHT)
        assertEquals(listOf(StrokeType.FOREHAND, StrokeType.BACKHAND, StrokeType.FOREHAND), report.strokes.map { it.type })
        assertEquals(1, report.rallies)
        assertEquals(listOf(StrokeType.FOREHAND, StrokeType.BACKHAND), report.summaries.map { it.type })
        assertEquals(2, report.summaries.first().count)
        assertEquals(1.0, report.splitStepRate)
        assertNotNull(report.movementMeters)
    }

    @Test fun noSplitStepIsCoached() {
        val report = MatchAnalyzer.analyze(sequence(rally(split = false), until = 9.5), Handedness.RIGHT)
        assertEquals(0.0, report.splitStepRate)
        assertTrue(Coach.ruleBased(report).improvements.any { it.title == "Split step before every shot" })
        val prompt = Coach.matchPrompt(report, Handedness.RIGHT)
        assertTrue("Split step before 0% of groundstrokes" in prompt)
        assertTrue("- Forehand: 2 hit" in prompt)
    }

    @Test fun longPausesSplitRallies() {
        val keys = groundstroke(c = 1.0) + groundstroke(c = 9.0)
        assertEquals(2, MatchAnalyzer.analyze(sequence(keys, until = 10.5), Handedness.RIGHT).rallies)
    }

    @Test fun emptyMatch() {
        val report = MatchAnalyzer.analyze(sequence(listOf(0.0 to emptyMap(), 5.0 to emptyMap()), until = 5.0), Handedness.RIGHT)
        assertTrue(report.strokes.isEmpty())
        assertTrue(Coach.ruleBased(report).summary.startsWith("No strokes were found"))
    }

    @Test fun strokeCoachingAndMatchParsing() {
        val stroke = assertNotNull(StrokeAnalyzer.analyzeClip(sequence(groundstroke(backhand = true, twoHanded = true), until = 2.0), hand = Handedness.RIGHT))
        val prompt = Coach.prompt(stroke, Handedness.RIGHT, hasImages = true)
        assertTrue("The images show the two-handed backhand in order: preparation, contact, finish." in prompt)
        assertTrue("Stroke: Two-handed backhand." in prompt)
        assertTrue("[contact-in-front]" in prompt)

        val report = MatchAnalyzer.analyze(sequence(rally(split = false), until = 9.5), Handedness.RIGHT)
        val reply = """{"summary":"Good rally with solid groundstrokes.","measurement_review":[{"check_id":"knee-bend","trustworthy":true,"note":"x"}],"strengths":["Consistent"],"improvements":[{"title":"Split step","why":"Faster first step to the ball.","how":"Hop as they hit.","drill":"Say hop out loud."}],"next_session_focus":"Split step every ball."}"""
        val parsed = assertNotNull(Coach.parse(reply, report, "Test"))
        assertTrue(parsed.measurementReview.isEmpty())
        assertEquals(Coach.ruleBased(report).strengths, parsed.strengths)
        assertTrue("Doing well:" in Coach.matchPrompt(report, Handedness.RIGHT))
        assertEquals("Split step", parsed.improvements.first().title)
    }

    @Test fun trackerReportsStrokeAfterFinish() {
        val tracker = StrokeTracker(Handedness.RIGHT, null)
        val results = sequence(groundstroke(), until = 2.5).mapNotNull { tracker.add(it) }
        assertEquals(1, results.size)
        assertEquals(StrokeType.FOREHAND, results.first().type)
    }
}
