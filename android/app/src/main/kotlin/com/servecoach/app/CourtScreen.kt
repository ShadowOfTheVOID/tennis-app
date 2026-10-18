package com.servecoach.app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.servecoach.analysis.Court
import com.servecoach.analysis.CourtAnalysis
import com.servecoach.analysis.Depth
import com.servecoach.analysis.Placement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.min
import kotlin.math.roundToInt

/** Shot placement from bounces, once the court has been marked on the video. */
@Composable
fun PlacementCard(vm: AppViewModel, match: AnalyzedMatch) {
    val taps = vm.courtTaps[match.id]
    var marking by remember { mutableStateOf(false) }
    val placement = remember(match.id, taps) {
        val court = taps?.let { Court.calibrate(it) } ?: return@remember null
        val feet = match.samples.values.mapNotNull { CourtAnalysis.feet(it.pose, it.imageWidth.toDouble(), it.imageHeight.toDouble()) }
        CourtAnalysis.placement(match.balls, court, feet)
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Shot placement (approximate)", style = MaterialTheme.typography.titleMedium)
            when {
                placement == null -> Text("Mark the four corners of the singles court on the video to see where your shots land, " +
                    "whether they're in, and how deep they go.")
                placement.yours.isEmpty() -> Text("No bounces were seen on your opponent's side. Bounces are found from the tracked " +
                    "ball, so a clear view of the far court and good light help.")
                else -> PlacementSummary(placement)
            }
            OutlinedButton(onClick = { marking = true }, modifier = Modifier.fillMaxWidth()) {
                Text(if (taps == null) "Mark the court" else "Mark the court again")
            }
        }
    }
    if (marking) {
        CourtSetupDialog(match, onDone = { vm.courtTaps[match.id] = it; marking = false }, onDismiss = { marking = false })
    }
}

@Composable
private fun PlacementSummary(p: Placement) {
    val total = p.yours.size
    val inCount = p.yours.count { it.isIn }
    Text("$inCount of $total landed in (${((p.inRate ?: 0.0) * 100).roundToInt()}%) · ${p.long} long · ${p.wide} wide",
        fontWeight = FontWeight.SemiBold)
    Text(Depth.entries.joinToString("  ·  ") { d -> "${d.title} ${((p.depthRate(d) ?: 0.0) * 100).roundToInt()}%" },
        style = MaterialTheme.typography.bodyMedium)
    CourtDiagram(p, Modifier.fillMaxWidth().aspectRatio(0.75f))
    Text("● in   ○ out. Short: inside the service line. Deep: the last 3 m.", style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
    p.tip?.let { Text(it, fontWeight = FontWeight.Medium) }
}

/** Your opponent's half of the court, with where your shots bounced. */
@Composable
private fun CourtDiagram(p: Placement, modifier: Modifier) {
    val mark = if (isSystemInDarkTheme()) Color(0xFF3987E5) else Color(0xFF2A78D6)
    val lines = MaterialTheme.colorScheme.outline
    val surface = MaterialTheme.colorScheme.surfaceContainerHighest
    // Your shots land on the far half; show that half with the net at the bottom.
    val farHalf = p.yours.firstOrNull()?.half ?: 1
    Canvas(modifier.background(surface)) {
        val margin = 2.5 // metres shown beyond the lines, so outs are visible
        val spanX = Court.WIDTH + 2 * margin
        val spanY = Court.NET + margin + 1.0
        val scale = min(size.width / spanX, size.height / spanY).toFloat()
        val ox = (size.width - spanX.toFloat() * scale) / 2
        fun at(x: Double, y: Double): Offset {
            val fromNet = if (farHalf == 1) y - Court.NET else Court.NET - y // 0 at the net, up the screen
            return Offset(ox + ((x + margin) * scale).toFloat(), size.height - ((fromNet + 1.0) * scale).toFloat())
        }
        val stroke = 2.dp.toPx()
        fun line(x1: Double, y1: Double, x2: Double, y2: Double) = drawLine(lines, at(x1, y1), at(x2, y2), stroke)
        val baseline = if (farHalf == 1) Court.LENGTH else 0.0
        val service = if (farHalf == 1) Court.NET + Court.SERVICE else Court.NET - Court.SERVICE
        line(0.0, Court.NET, Court.WIDTH, Court.NET)
        line(0.0, baseline, Court.WIDTH, baseline)
        line(0.0, Court.NET, 0.0, baseline)
        line(Court.WIDTH, Court.NET, Court.WIDTH, baseline)
        line(0.0, service, Court.WIDTH, service)
        line(Court.WIDTH / 2, Court.NET, Court.WIDTH / 2, service)
        for (b in p.yours) {
            val c = at(b.x, b.y)
            if (b.isIn) {
                drawCircle(surface, 6.dp.toPx(), c)
                drawCircle(mark, 5.dp.toPx(), c)
            } else {
                drawCircle(mark, 5.dp.toPx(), c, style = Stroke(2.dp.toPx()))
            }
        }
    }
}

/** Tap the four corners of the singles court on a frame of the video. */
@Composable
private fun CourtSetupDialog(match: AnalyzedMatch, onDone: (List<Pair<Double, Double>>) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var frame by remember { mutableStateOf<Bitmap?>(null) }
    val taps = remember { mutableStateListOf<Pair<Double, Double>>() }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(match.id) {
        frame = withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, match.video)
                val t = match.report.strokes.firstOrNull()?.time ?: 0.0
                retriever.getScaledFrameAtTime((t * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 1280, 1280)
            } catch (e: Exception) {
                null
            } finally {
                retriever.release()
            }
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Card(Modifier.fillMaxWidth().padding(12.dp)) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Mark the court", style = MaterialTheme.typography.titleMedium)
                Text(
                    when (taps.size) {
                        0 -> "Tap one end of a baseline of the singles court."
                        1 -> "Now the other end of the same baseline."
                        2 -> "Now the far corner on that side of the court."
                        3 -> "And the last corner."
                        else -> "Done? Check the outline matches the singles lines."
                    },
                )
                val image = frame
                if (image == null) {
                    Text("Loading a frame…")
                } else {
                    Box(Modifier.fillMaxWidth().aspectRatio(image.width.toFloat() / image.height).background(Color.Black)) {
                        Image(image.asImageBitmap(), "Video frame", Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                        Canvas(
                            Modifier.fillMaxSize().pointerInput(Unit) {
                                detectTapGestures { o ->
                                    if (taps.size < 4) taps += (o.x / size.width).toDouble() to (o.y / size.height).toDouble()
                                    error = null
                                }
                            },
                        ) {
                            val points = taps.map { Offset((it.first * size.width).toFloat(), (it.second * size.height).toFloat()) }
                            for (i in points.indices) {
                                if (i > 0) drawLine(Color.Yellow, points[i - 1], points[i], 2.dp.toPx())
                                drawCircle(Color.Yellow, 6.dp.toPx(), points[i])
                            }
                            if (points.size == 4) drawLine(Color.Yellow, points[3], points[0], 2.dp.toPx())
                        }
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    TextButton(onClick = { if (taps.isNotEmpty()) taps.removeAt(taps.lastIndex) }, enabled = taps.isNotEmpty()) { Text("Undo") }
                    Button(
                        onClick = {
                            if (Court.calibrate(taps.toList()) == null) {
                                error = "Those corners don't make a court shape. Tap them in order around the court."
                            } else onDone(taps.toList())
                        },
                        enabled = taps.size == 4,
                    ) { Text("Done") }
                }
            }
        }
    }
}
