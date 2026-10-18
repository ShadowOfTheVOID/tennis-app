package com.servecoach.analysis

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HistoryTest {
    private fun record(score: Int?, fix: String? = null) =
        PracticeRecord(kind = "forehand", score = score, detail = "", topFix = fix, handedness = "right")

    @Test fun storePersistsNewestFirst() {
        val file = Files.createTempDirectory("history").resolve("sub/history.json").toFile()
        val store = HistoryStore(file)
        val first = record(80)
        val second = record(90)
        store.add(first)
        store.add(second)
        assertEquals(listOf(second.id, first.id), HistoryStore(file).records.map { it.id })
        val match = PracticeRecord.of(MatchAnalyzer.analyze(emptyList(), Handedness.RIGHT), Handedness.RIGHT)
        assertEquals("Match", match.title)
        assertEquals("forehand", first.kind)
        store.clear()
        assertTrue(HistoryStore(file).records.isEmpty())
    }

    @Test fun trendAndCommonFix() {
        val records = listOf(90, 90, 90, 90, 90, 70, 70, 70, 70, 70).map { record(it, "Knees loaded") } +
            record(null, "Hitting elbow ~90°")
        assertEquals(20, HistoryStats.trend(records))
        assertNull(HistoryStats.trend(records.take(6)))
        assertEquals("Knees loaded", HistoryStats.mostCommonFix(records))
    }
}
