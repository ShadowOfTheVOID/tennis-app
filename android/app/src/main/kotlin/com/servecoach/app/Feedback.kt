package com.servecoach.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.Check
import com.servecoach.analysis.Evaluation
import com.servecoach.analysis.Joint
import com.servecoach.analysis.Status
import kotlin.math.max
import kotlin.math.min

val Status.color: Color
    get() = when (this) {
        Status.GOOD -> Color(0xFF2E9E4F)
        Status.WARN -> Color(0xFFE08A00)
        Status.BAD -> Color(0xFFD93025)
        Status.UNKNOWN -> Color.Gray
    }

fun scoreColor(score: Int?) = when {
    score == null -> Color.Gray
    score >= 80 -> Status.GOOD.color
    score >= 50 -> Status.WARN.color
    else -> Status.BAD.color
}

@Composable
fun ScoreBadge(score: Int?, modifier: Modifier = Modifier) {
    val color = scoreColor(score)
    Text(
        text = score?.toString() ?: "—",
        style = MaterialTheme.typography.titleLarge,
        fontWeight = FontWeight.Bold,
        modifier = modifier
            .size(56.dp)
            .background(color.copy(alpha = 0.18f), CircleShape)
            .border(3.dp, color, CircleShape)
            .padding(top = 12.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
fun CheckRow(check: Check, distrusted: Boolean = false) {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
        val icon = when (check.status) {
            Status.GOOD -> Icons.Filled.CheckCircle
            Status.WARN -> Icons.Filled.Warning
            Status.BAD -> Icons.Filled.Cancel
            Status.UNKNOWN -> Icons.Filled.Help
        }
        Icon(icon, contentDescription = check.status.name, tint = check.status.color)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row {
                Text(check.label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text(check.value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (distrusted) {
                Text("AI coach thinks this measurement may be wrong.", style = MaterialTheme.typography.bodySmall, color = Status.WARN.color)
            }
            if (check.status != Status.GOOD) {
                Text(check.tip, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
fun EvaluationCard(evaluation: Evaluation, distrusted: Set<String> = emptySet()) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(evaluation.phase.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                ScoreBadge(evaluation.score)
            }
            evaluation.checks.forEach { CheckRow(it, distrusted = it.id in distrusted) }
        }
    }
}

private val BONES = listOf(
    Joint.LEFT_SHOULDER to Joint.RIGHT_SHOULDER, Joint.LEFT_HIP to Joint.RIGHT_HIP,
    Joint.LEFT_SHOULDER to Joint.LEFT_HIP, Joint.RIGHT_SHOULDER to Joint.RIGHT_HIP,
    Joint.LEFT_SHOULDER to Joint.LEFT_ELBOW, Joint.LEFT_ELBOW to Joint.LEFT_WRIST,
    Joint.RIGHT_SHOULDER to Joint.RIGHT_ELBOW, Joint.RIGHT_ELBOW to Joint.RIGHT_WRIST,
    Joint.LEFT_HIP to Joint.LEFT_KNEE, Joint.LEFT_KNEE to Joint.LEFT_ANKLE,
    Joint.RIGHT_HIP to Joint.RIGHT_KNEE, Joint.RIGHT_KNEE to Joint.RIGHT_ANKLE,
)

/**
 * Draws a pose skeleton over content of the sample's image size, laid out with the same
 * center-crop ([fill]) or fit as the content beneath it.
 */
@Composable
fun SkeletonOverlay(sample: PoseSample?, modifier: Modifier = Modifier, fill: Boolean = true, mirrored: Boolean = false, color: Color = Color.Green) {
    Canvas(modifier) {
        if (sample == null || sample.imageWidth <= 0 || sample.imageHeight <= 0) return@Canvas
        val iw = sample.imageWidth.toFloat()
        val ih = sample.imageHeight.toFloat()
        val scale = if (fill) max(size.width / iw, size.height / ih) else min(size.width / iw, size.height / ih)
        val ox = (size.width - iw * scale) / 2
        val oy = (size.height - ih * scale) / 2
        fun map(j: Joint): Offset? = sample.pose[j]?.let {
            val x = if (mirrored) iw - it.x.toFloat() else it.x.toFloat()
            Offset(x * scale + ox, it.y.toFloat() * scale + oy)
        }
        for ((a, b) in BONES) {
            val pa = map(a) ?: continue
            val pb = map(b) ?: continue
            drawLine(color, pa, pb, strokeWidth = 4.dp.toPx(), cap = StrokeCap.Round)
        }
        for (j in Joint.entries) map(j)?.let { drawCircle(Color.White, 5.dp.toPx(), it) }
    }
}
