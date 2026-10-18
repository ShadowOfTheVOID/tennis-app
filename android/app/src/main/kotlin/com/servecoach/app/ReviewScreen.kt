package com.servecoach.app

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.CoachReport
import com.servecoach.analysis.CoachSource
import com.servecoach.analysis.PoseAlignment
import com.servecoach.analysis.StrokeResult
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import androidx.compose.material.icons.filled.Share

/** A stroke's key frames and checks, plus the AI coach's improvement plan. */
@Composable
fun ReviewScreen(vm: AppViewModel, stroke: ReviewedStroke) {
    val report = vm.reports[stroke.id]
    val distrusted = report?.distrustedChecks ?: emptySet()
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(stroke.result.title, style = MaterialTheme.typography.headlineSmall)
        StrokeStats(stroke.result)

        // "Compare with your best": a ghost of your best-scoring stroke of the same kind.
        val best = remember(stroke.id, vm.history) { vm.bestFor(stroke) }
        var showGhost by remember { mutableStateOf(false) }
        if (best != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Compare with your best (${best.score}/100)", Modifier.weight(1f))
                androidx.compose.material3.Switch(showGhost, { showGhost = it })
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            stroke.result.keyFrames.forEach { key ->
                val sample = stroke.samples[key.phase]
                val ghost = if (!showGhost || best == null || sample == null) null else best.pose(key.phase)?.let { g ->
                    PoseAlignment.align(g, best.direction ?: 1.0, sample.pose, stroke.result.direction)
                }?.let { PoseSample(it, sample.imageWidth, sample.imageHeight) }
                KeyFrame(key.phase.title, stroke.images[key.phase], sample, Modifier.weight(1f), ghost)
            }
        }
        if (showGhost && best != null) {
            Text("White: this stroke. Grey: your best. Lined up at the hips.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        if (stroke.replay.size >= 2) Replay(stroke.replay)
        ShareClipButton(stroke)

        if (report != null) {
            CoachReportCard(report, stroke.result.score, stroke.result.checks.associate { it.id to it.label })
        } else {
            CoachButton(vm, stroke.id, onClick = { vm.requestCoaching(stroke) }, photos = true)
        }

        stroke.result.evaluations.forEach { EvaluationCard(it, distrusted) }
    }
}

/** Exports the replay with the skeleton and scores drawn on, then opens the share sheet. */
@Composable
private fun ShareClipButton(stroke: ReviewedStroke) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var busy by remember(stroke.id) { mutableStateOf(false) }
    var error by remember(stroke.id) { mutableStateOf<String?>(null) }
    androidx.compose.material3.OutlinedButton(
        onClick = {
            busy = true
            error = null
            scope.launch {
                runCatching { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { ClipExporter.export(context, stroke) } }
                    .onSuccess { ClipExporter.share(context, it) }
                    .onFailure { error = "Couldn't make the clip: ${it.message}" }
                busy = false
            }
        },
        enabled = !busy && (stroke.replay.isNotEmpty() || stroke.images.isNotEmpty()),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(Icons.Filled.Share, null)
        Spacer(Modifier.width(6.dp))
        Text(if (busy) "Making clip…" else "Share clip")
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
}

/** "How do I improve?" with progress and a note on which coach will answer. */
@Composable
fun CoachButton(vm: AppViewModel, id: String, onClick: () -> Unit, photos: Boolean) {
    val busy = vm.coaching[id] == true
    val model = vm.activeModel
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Button(onClick = onClick, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.AutoAwesome, null)
            Spacer(Modifier.width(6.dp))
            Text(if (busy) "Coach is reviewing…" else "How do I improve?")
        }
        if (busy) {
            Spacer(Modifier.padding(4.dp))
            CircularProgressIndicator()
            if (model != null) Text("This takes 1–2 minutes on most phones.", style = MaterialTheme.typography.bodySmall)
        }
        Text(
            when {
                model == null -> "Using the built-in coach. Download an AI model in Settings for personalised, offline AI coaching."
                model.vision && photos -> "${model.name} runs on your phone and checks the measurements against your photos. Nothing is uploaded."
                else -> "${model.name} runs on your phone and double-checks the analysis. Nothing is uploaded."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun KeyFrame(title: String, image: Bitmap?, sample: PoseSample?, modifier: Modifier, ghost: PoseSample? = null) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(12.dp)).background(Color.Black), contentAlignment = Alignment.Center) {
            if (image != null) {
                Image(image.asImageBitmap(), title, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                ghost?.let { SkeletonOverlay(it, Modifier.fillMaxSize(), fill = false, color = Color.LightGray.copy(alpha = 0.7f)) }
                SkeletonOverlay(sample, Modifier.fillMaxSize(), fill = false, color = if (ghost != null) Color.White else Color.Green)
            } else {
                Text("No frame", color = Color.Gray)
            }
        }
        Text(title, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
fun CoachReportCard(report: CoachReport, score: Int?, labels: Map<String, String>) {
    var showReview by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val ai = report.source == CoachSource.ON_DEVICE_AI
                Icon(if (ai) Icons.Filled.AutoAwesome else Icons.Filled.Checklist, null)
                Spacer(Modifier.width(6.dp))
                Column(Modifier.weight(1f)) {
                    Text(if (ai) "AI coach" else "Coach", style = MaterialTheme.typography.titleMedium)
                    report.modelName?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
                ScoreBadge(score)
            }
            Text(report.summary)

            if (report.strengths.isNotEmpty()) {
                Section("What's working")
                report.strengths.forEach {
                    Row {
                        Icon(Icons.Filled.ThumbUp, null, tint = Color(0xFF2E9E4F))
                        Spacer(Modifier.width(6.dp))
                        Text(it, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }

            if (report.improvements.isNotEmpty()) {
                Section("How to improve")
                report.improvements.forEachIndexed { i, item ->
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                        Column(Modifier.padding(12.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("${i + 1}. ${item.title}", fontWeight = FontWeight.SemiBold)
                            Text(item.why, style = MaterialTheme.typography.bodySmall)
                            Text("Cue: ${item.how}")
                            Row {
                                Icon(Icons.Filled.SportsTennis, null)
                                Spacer(Modifier.width(6.dp))
                                Text(item.drill, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                }
            }

            Section("Next session focus")
            Text(report.nextSessionFocus, fontWeight = FontWeight.Medium)

            if (report.measurementReview.isNotEmpty()) {
                TextButton(onClick = { showReview = !showReview }) {
                    Text(if (showReview) "Hide measurement check" else "Show measurement check")
                }
                if (showReview) {
                    report.measurementReview.forEach { r ->
                        Row {
                            Icon(
                                if (r.trustworthy) Icons.Filled.Verified else Icons.Filled.Warning, null,
                                tint = if (r.trustworthy) Color(0xFF2E9E4F) else Color(0xFFE08A00),
                            )
                            Spacer(Modifier.width(6.dp))
                            Column {
                                Text(labels[r.checkId] ?: r.checkId, style = MaterialTheme.typography.labelLarge)
                                Text(r.note, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Estimated hand speed and, for serves, rhythm. */
@Composable
fun StrokeStats(result: StrokeResult) {
    val speed = result.swingSpeed
    val tempo = result.tempo
    if (speed == null && tempo == null) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        speed?.let { StatChip("Hand speed", "≈ %.1f m/s (%d km/h)".format(it, (it * 3.6).roundToInt())) }
        tempo?.let { StatChip("Rhythm", "%.2f s trophy → contact".format(it)) }
    }
}

@Composable
private fun StatChip(label: String, value: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(label, style = MaterialTheme.typography.labelSmall)
            Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Frame-by-frame replay with the skeleton, scrubbed with a slider or played at quarter speed. */
@Composable
fun Replay(frames: List<ReplayFrame>) {
    var index by remember(frames) { mutableIntStateOf(0) }
    var playing by remember(frames) { mutableStateOf(false) }
    LaunchedEffect(playing) {
        while (playing) {
            val gap = if (index + 1 < frames.size) frames[index + 1].time - frames[index].time else 0.1
            kotlinx.coroutines.delay((gap * 4 * 1000).toLong().coerceIn(40, 1000)) // quarter speed
            if (index + 1 < frames.size) index++ else { index = 0; playing = false }
        }
    }
    val frame = frames[index.coerceIn(frames.indices)]
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Slow-motion replay", style = MaterialTheme.typography.titleMedium)
            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(12.dp)).background(Color.Black)) {
                Image(frame.image.asImageBitmap(), "Replay frame", Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                SkeletonOverlay(frame.sample, Modifier.fillMaxSize(), fill = false)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.IconButton(onClick = { playing = !playing }) {
                    Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play at quarter speed")
                }
                androidx.compose.material3.Slider(
                    value = index.toFloat(),
                    onValueChange = { playing = false; index = it.roundToInt() },
                    valueRange = 0f..(frames.size - 1).toFloat(),
                    steps = (frames.size - 2).coerceAtLeast(0),
                    modifier = Modifier.weight(1f),
                )
            }
            Text("%+.2f s from the first frame · frame %d of %d".format(frame.time - frames.first().time, index + 1, frames.size),
                style = MaterialTheme.typography.bodySmall)
        }
    }
}
