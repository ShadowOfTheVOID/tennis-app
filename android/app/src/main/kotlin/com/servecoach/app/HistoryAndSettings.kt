package com.servecoach.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.CoachModel
import com.servecoach.analysis.HistoryStats
import java.text.DateFormat
import java.util.Date

@Composable
fun HistoryScreen(vm: AppViewModel) {
    var filter by remember { mutableStateOf<String?>(null) }
    val kinds = vm.history.map { it.kind }.distinct()
    val records = vm.history.filter { filter == null || it.kind == filter }
    var confirmClear by remember { mutableStateOf(false) }
    if (vm.history.isEmpty()) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Nothing yet", style = MaterialTheme.typography.titleLarge)
            Text("Strokes you record live and videos you analyze show up here so you can track progress.")
        }
        return
    }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            androidx.compose.foundation.lazy.LazyRow(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(listOf<String?>(null) + kinds) { kind ->
                    androidx.compose.material3.FilterChip(
                        selected = filter == kind,
                        onClick = { filter = kind },
                        label = { Text(kind?.let { k -> vm.history.first { it.kind == k }.title } ?: "All") },
                    )
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val scores = records.mapNotNull { it.score }
                    val noun = filter?.let { k -> vm.history.first { it.kind == k }.title.lowercase() + if (k == "match") "es" else "s" } ?: "sessions"
                    Text("${records.size} $noun", style = MaterialTheme.typography.titleMedium)
                    if (scores.isNotEmpty()) Text("Average score: ${scores.take(10).average().toInt()} (last ${minOf(10, scores.size)})")
                    // A trend only means something within one kind of stroke.
                    HistoryStats.trend(records).takeIf { filter != null }?.let { t ->
                        Text(
                            when {
                                t > 0 -> "Trending up: +$t points over your last 5"
                                t < 0 -> "Trending down: $t points over your last 5"
                                else -> "Holding steady over your last 5"
                            },
                            color = if (t >= 0) Status_GOOD else Status_WARN,
                        )
                    }
                    HistoryStats.mostCommonFix(records)?.let { Text("Most common fix: $it", fontWeight = FontWeight.Medium) }
                }
            }
        }
        items(records, key = { it.id }) { r ->
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(r.title, style = MaterialTheme.typography.titleSmall)
                        Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(r.date)), style = MaterialTheme.typography.labelMedium)
                        Text(r.detail, style = MaterialTheme.typography.bodySmall)
                        r.topFix?.let { Text("Fix: $it", style = MaterialTheme.typography.bodySmall) }
                    }
                    ScoreBadge(r.score)
                }
            }
        }
        item {
            TextButton(onClick = { confirmClear = true }, modifier = Modifier.padding(bottom = 16.dp)) { Text("Clear history") }
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear all history?") },
            text = { Text("This deletes every saved stroke and match from this phone.") },
            confirmButton = { TextButton(onClick = { vm.clearHistory(); confirmClear = false }) { Text("Clear") } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
        )
    }
}

private val Status_GOOD = com.servecoach.analysis.Status.GOOD.color
private val Status_WARN = com.servecoach.analysis.Status.WARN.color

@Composable
fun SettingsScreen(vm: AppViewModel) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Player", style = MaterialTheme.typography.titleMedium)
        HandPicker(vm.hand, vm::updateHand, Modifier.fillMaxWidth())
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Spoken tips after each stroke", Modifier.weight(1f))
            Switch(vm.spokenCues, vm::updateSpokenCues)
        }

        Text("AI coach", style = MaterialTheme.typography.titleMedium)
        Text(
            "Download a free AI model once and it runs entirely on your phone: no account, no API key, works offline. " +
                "Without one you still get the built-in coach.",
            style = MaterialTheme.typography.bodySmall,
        )
        val recommended = vm.models.recommended
        Text(
            "This phone: %.1f GB RAM, %.1f GB free storage. %s"
                    .format(
                        vm.models.deviceRamBytes / 1e9, vm.models.freeBytes / 1e9,
                        if (recommended == null) "That's below what the AI model needs, so the built-in coach is used." else "",
                    ),
            style = MaterialTheme.typography.bodySmall,
        )
        CoachModel.ALL.forEach { ModelCard(vm, it, recommended = it == recommended) }
    }
}

@Composable
private fun ModelCard(vm: AppViewModel, model: CoachModel, recommended: Boolean) {
    val installed = vm.isInstalled(model)
    val download = vm.downloads[model.id]
    var confirmDelete by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (installed) RadioButton(selected = vm.activeModel == model, onClick = { vm.selectModel(model) })
                Column(Modifier.weight(1f)) {
                    Text(model.name + if (recommended) "  ·  Recommended" else "", fontWeight = FontWeight.SemiBold)
                    Text("%.1f GB download".format(model.sizeBytes / 1e9), style = MaterialTheme.typography.bodySmall)
                }
            }
            Text(model.summary, style = MaterialTheme.typography.bodySmall)
            when {
                download is DownloadState.Running -> {
                    LinearProgressIndicator(progress = { download.progress }, modifier = Modifier.fillMaxWidth())
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Downloading… ${(download.progress * 100).toInt()}%  (keep the app open, Wi-Fi recommended)", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = { vm.cancelDownload(model) }) { Text("Cancel") }
                    }
                }
                installed -> OutlinedButton(onClick = { confirmDelete = true }) { Text("Delete") }
                else -> {
                    if (download is DownloadState.Failed) Text(download.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    Button(onClick = { vm.download(model) }) { Text(if (download is DownloadState.Failed) "Retry download" else "Download") }
                }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${model.name}?") },
            text = { Text("Frees %.1f GB. You can download it again later.".format(model.sizeBytes / 1e9)) },
            confirmButton = { TextButton(onClick = { vm.deleteModel(model); confirmDelete = false }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}
