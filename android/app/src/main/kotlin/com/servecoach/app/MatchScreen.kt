package com.servecoach.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.StrokeResult
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Everything from a match video: stroke breakdown, footwork, AI match plan, and every stroke to review. */
@Composable
fun MatchScreen(vm: AppViewModel, match: AnalyzedMatch, onReview: (ReviewedStroke) -> Unit) {
    val report = match.report
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var opening by remember { mutableStateOf<StrokeResult?>(null) }

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(Modifier.fillMaxWidth().padding(top = 16.dp)) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Match", style = MaterialTheme.typography.titleLarge)
                        Text(report.countsText)
                        Text("%d:%02d of video".format(report.duration.toInt() / 60, report.duration.toInt() % 60), style = MaterialTheme.typography.bodySmall)
                    }
                    ScoreBadge(report.score)
                }
            }
        }

        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Strokes", style = MaterialTheme.typography.titleMedium)
                    report.summaries.forEach { s ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("${s.type.title} × ${s.count}", fontWeight = FontWeight.SemiBold)
                                s.commonFix?.let { Text("Most often missed: ${it.label}", style = MaterialTheme.typography.bodySmall) }
                            }
                            ScoreBadge(s.averageScore)
                        }
                    }
                    Text("Stroke types are detected from body position and can occasionally be wrong.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Footwork (estimated)", style = MaterialTheme.typography.titleMedium)
                    report.splitStepRate?.let { Stat("Split step before the shot", "${(it * 100).roundToInt()}%", good = it >= 0.7) }
                    report.readyStanceRate?.let { Stat("Knees bent between shots", "${(it * 100).roundToInt()}%", good = it >= 0.7) }
                    report.movementMeters?.takeIf { it >= 1 }?.let { Stat("Side-to-side movement", "≈ ${it.roundToInt()} m", good = null) }
                    if (report.splitStepRate == null && report.readyStanceRate == null) {
                        Text("Not enough of your feet were visible to judge footwork.", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }

        item { BallCard(match, vm.hand) }
        item { PlacementCard(vm, match) }

        item {
            val coachReport = vm.reports[match.id]
            if (coachReport != null) {
                CoachReportCard(coachReport, report.score, emptyMap())
            } else {
                CoachButton(vm, match.id, onClick = { vm.requestCoaching(match) }, photos = false)
            }
        }

        item { Text("Every stroke", style = MaterialTheme.typography.titleMedium) }
        items(report.strokes, key = { it.time }) { stroke ->
            Card(Modifier.fillMaxWidth().clickable(enabled = opening == null) {
                opening = stroke
                scope.launch {
                    try {
                        onReview(VideoAnalyzer.stills(context, match.video, stroke, match.samples, match.balls, vm.hand))
                    } finally {
                        opening = null
                    }
                }
            }) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("%d:%02d  %s".format(stroke.time.toInt() / 60, stroke.time.toInt() % 60, stroke.title), fontWeight = FontWeight.SemiBold)
                        stroke.topTip?.let { Text("Fix: ${it.label}", style = MaterialTheme.typography.bodySmall) }
                        if (stroke.splitStep == false) Text("No split step seen", style = MaterialTheme.typography.bodySmall)
                    }
                    if (opening == stroke) CircularProgressIndicator(Modifier.padding(8.dp)) else ScoreBadge(stroke.score)
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Review")
                }
            }
        }
        item { Spacer(Modifier.padding(8.dp)) }
    }
}

@Composable
private fun Stat(label: String, value: String, good: Boolean?) {
    Row {
        Text(label, Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text(
            value,
            fontWeight = FontWeight.SemiBold,
            color = when (good) {
                true -> com.servecoach.analysis.Status.GOOD.color
                false -> com.servecoach.analysis.Status.WARN.color
                null -> MaterialTheme.colorScheme.onSurface
            },
        )
    }
}

/** Rallies and toss consistency from ball tracking, which is approximate. */
@Composable
private fun BallCard(match: AnalyzedMatch, hand: com.servecoach.analysis.Handedness) {
    val rallies = match.rallies
    val tosses = remember(match.id, hand) { match.tosses(hand) }
    val consistency = com.servecoach.analysis.BallAnalysis.consistency(tosses)
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Ball tracking (approximate)", style = MaterialTheme.typography.titleMedium)
            if (rallies.isNotEmpty()) {
                val average = rallies.sumOf { it.shots }.toDouble() / rallies.size
                Text("%d rallies seen, about %.1f shots each, longest %d".format(rallies.size, average, rallies.maxOf { it.shots }))
            }
            if (consistency != null) {
                Text(consistency.verdict, fontWeight = FontWeight.SemiBold)
                Text("Over %d serves your toss peaked %.1f torso lengths above your head and %.1f in front of your shoulder, on average."
                    .format(consistency.count, consistency.average.height, consistency.average.forward), style = MaterialTheme.typography.bodyMedium)
                Text(consistency.average.tip, style = MaterialTheme.typography.bodySmall)
            } else if (tosses.isNotEmpty()) {
                Text(tosses.first().tip, style = MaterialTheme.typography.bodyMedium)
            }
            if (rallies.isEmpty() && tosses.isEmpty()) {
                Text("The ball wasn't tracked clearly enough. It works best in good light, with the ball against a darker background.")
            }
            Text("The ball blurs at speed, so fast shots are often missed and counts are estimates.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
