package com.servecoach.app

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.CheckProgress
import com.servecoach.analysis.PracticePlan

import com.servecoach.analysis.PracticeStats
import com.servecoach.analysis.StrokeType
import kotlin.math.roundToInt

/** Per-check progress for one stroke, serve rhythm and top hand speeds. */
@Composable
fun ProgressTab(vm: AppViewModel) {
    val kinds = StrokeType.entries.filter { t -> vm.history.any { it.kind == t.key } }
    var kind by remember { mutableStateOf<StrokeType?>(null) }
    val selected = kind ?: kinds.firstOrNull()
    if (selected == null) {
        Text("Record a few strokes to see your progress here.", Modifier.padding(24.dp))
        return
    }
    val progress = remember(vm.history, selected) { PracticeStats.progress(vm.history, selected.key) }
    val rhythm = remember(vm.history) { PracticeStats.rhythm(vm.history) }
    val speeds = remember(vm.history) { PracticeStats.topSpeeds(vm.history) }

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            LazyRow(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(kinds) { t -> FilterChip(selected == t, { kind = t }, label = { Text(t.title) }) }
            }
        }
        speeds[selected.key]?.let { top ->
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text("Fastest ${selected.title.lowercase()}", style = MaterialTheme.typography.labelLarge)
                        Text("≈ %.1f m/s hand speed (%d km/h)".format(top, (top * 3.6).roundToInt()), style = MaterialTheme.typography.titleMedium)
                        Text("Estimated from your hand, not the racket head, which moves faster.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        if (selected == StrokeType.SERVE && rhythm != null) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Serve rhythm", style = MaterialTheme.typography.labelLarge)
                        Text(rhythm.verdict, style = MaterialTheme.typography.titleMedium)
                        Text("%.2f s from trophy to contact on average, ± %.2f s over %d serves".format(rhythm.average, rhythm.spread, rhythm.count))
                        Text(rhythm.tip, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        item { Text("Each check: share graded good per week", style = MaterialTheme.typography.titleSmall) }
        items(progress, key = { it.id }) { ProgressTile(it) }
        item { Text("", Modifier.padding(8.dp)) }
    }
}

/** One check: latest rate, change, and a weekly sparkline (single series, so no legend). */
@Composable
private fun ProgressTile(p: CheckProgress) {
    val latest = p.weeks.lastOrNull()?.goodRate ?: 0.0
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(p.label, fontWeight = FontWeight.SemiBold)
                Text(p.summary, style = MaterialTheme.typography.bodySmall)
            }
            Column(horizontalAlignment = Alignment.End, modifier = Modifier.padding(horizontal = 8.dp)) {
                Text("${(latest * 100).roundToInt()}%", style = MaterialTheme.typography.titleMedium)
                // Direction is shown with an arrow, not colour alone.
                p.change?.let { Text(if (it > 0) "▲ +$it pts" else if (it < 0) "▼ $it pts" else "– no change", style = MaterialTheme.typography.labelSmall) }
            }
            Sparkline(p, Modifier.width(96.dp).height(36.dp))
        }
    }
}

@Composable
private fun Sparkline(p: CheckProgress, modifier: Modifier) {
    val line = if (isSystemInDarkTheme()) Color(0xFF3987E5) else Color(0xFF2A78D6)
    val grid = MaterialTheme.colorScheme.outlineVariant
    val surface = MaterialTheme.colorScheme.surfaceContainerHighest
    Canvas(modifier) {
        // x: weeks (oldest left), y: 0–100 % good. Recessive baseline only.
        drawLine(grid, Offset(0f, size.height), Offset(size.width, size.height), strokeWidth = 1.dp.toPx())
        if (p.weeks.isEmpty()) return@Canvas
        val oldest = p.weeks.first().weeksAgo.coerceAtLeast(1)
        val points = p.weeks.map { w ->
            val x = if (p.weeks.size == 1) size.width else size.width * (1f - w.weeksAgo.toFloat() / oldest)
            Offset(x, size.height * (1f - w.goodRate.toFloat()))
        }
        if (points.size > 1) {
            val path = Path().apply { moveTo(points[0].x, points[0].y); points.drop(1).forEach { lineTo(it.x, it.y) } }
            drawPath(path, line, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
        }
        // End marker with a surface ring, so it reads over the line.
        drawCircle(surface, 5.dp.toPx(), points.last())
        drawCircle(line, 4.dp.toPx(), points.last())
    }
}

/** This week's practice plan, and the daily reminder. */
@Composable
fun PlanTab(vm: AppViewModel) {
    val context = LocalContext.current
    val plan = remember(vm.history) { PracticePlan.make(vm.history) }
    var reminder by remember { mutableStateOf(Reminders.isOn(context)) }
    var hour by remember { mutableStateOf(Reminders.hour(context)) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) { Reminders.enable(context, hour); reminder = true }
    }
    fun turnOn() {
        if (Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        else { Reminders.enable(context, hour); reminder = true }
    }
    val today = if (reminder) Reminders.planDay(context) else null

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Card(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Your focus this week", style = MaterialTheme.typography.titleMedium)
                    if (plan.focus.isEmpty()) Text("Record some strokes and your plan will build itself from what needs the most work.")
                    plan.focus.forEach { f ->
                        Text("• ${f.strokeTitle}: ${f.label} — needed work ${(f.missRate * 100).roundToInt()}% of the time")
                    }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Daily reminder", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                        Switch(reminder, { on -> if (on) turnOn() else { Reminders.disable(context); reminder = false } })
                    }
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(listOf(7, 12, 18, 20)) { h ->
                            FilterChip(hour == h, {
                                hour = h
                                if (reminder) Reminders.enable(context, h)
                            }, label = { Text("%d:00".format(h)) })
                        }
                    }
                    Text("You'll get today's part of the plan at that time. Turning it on starts the week today.",
                        style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        items(plan.days, key = { it.day }) { day ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Day ${day.day}${if (day.day == today) " · today" else ""}: ${day.title}", fontWeight = FontWeight.SemiBold)
                    day.items.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
                }
            }
        }
        item { Text("", Modifier.padding(8.dp)) }
    }
}

