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
import com.servecoach.analysis.ServeResult

/** A serve's key frames and checks, plus the AI coach's improvement plan. */
@Composable
fun ReviewScreen(vm: AppViewModel, serve: ReviewedServe) {
    val report = vm.reports[serve.id]
    val distrusted = report?.distrustedChecks ?: emptySet()
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            KeyFrame("Trophy", serve.trophyImage, serve.trophySample, Modifier.weight(1f))
            KeyFrame("Contact", serve.contactImage, serve.contactSample, Modifier.weight(1f))
        }

        if (report != null) {
            CoachReportCard(report, serve.result)
        } else {
            val busy = vm.coaching[serve.id] == true
            val model = vm.activeModel
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                Button(onClick = { vm.requestCoaching(serve) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.AutoAwesome, null)
                    Spacer(Modifier.width(6.dp))
                    Text(if (busy) "Coach is reviewing your serve…" else "How do I improve?")
                }
                if (busy) {
                    Spacer(Modifier.padding(4.dp))
                    CircularProgressIndicator()
                    Text("This takes 1–2 minutes on most phones.", style = MaterialTheme.typography.bodySmall)
                }
                Text(
                    when {
                        model == null -> "Using the built-in coach. Download an AI model in Settings for personalised, offline AI coaching."
                        model.vision -> "${model.name} runs on your phone and checks the measurements against your photos. Nothing is uploaded."
                        else -> "${model.name} runs on your phone and double-checks the measurements. Nothing is uploaded."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }

        serve.result.trophy?.let { EvaluationCard(it, distrusted) }
        serve.result.contact?.let { EvaluationCard(it, distrusted) }
    }
}

@Composable
private fun KeyFrame(title: String, image: Bitmap?, sample: PoseSample?, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(12.dp)).background(Color.Black), contentAlignment = Alignment.Center) {
            if (image != null) {
                Image(image.asImageBitmap(), title, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                SkeletonOverlay(sample, Modifier.fillMaxSize(), fill = false)
            } else {
                Text("No frame", color = Color.Gray)
            }
        }
        Text(title, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
fun CoachReportCard(report: CoachReport, serve: ServeResult) {
    val labels = serve.checks.associate { it.id to it.label }
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
                ScoreBadge(serve.score)
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
