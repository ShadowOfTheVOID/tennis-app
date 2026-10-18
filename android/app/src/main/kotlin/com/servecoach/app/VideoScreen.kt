package com.servecoach.app

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.Frame
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.ServeAnalyzer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

object VideoAnalyzer {
    /** Frames sampled per second of video. */
    private const val SAMPLE_RATE = 15
    /** Longest stretch of video analysed; one serve takes a couple of seconds. */
    private const val MAX_SECONDS = 20

    suspend fun analyze(context: Context, uri: Uri, hand: Handedness, onProgress: (Float) -> Unit): ReviewedServe =
        withContext(Dispatchers.Default) {
            val retriever = MediaMetadataRetriever()
            val detector = BodyPoseDetector(stream = false)
            try {
                retriever.setDataSource(context, uri)
                val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                val count = maxOf(1, (minOf(durationMs, MAX_SECONDS * 1000L) * SAMPLE_RATE / 1000).toInt())

                fun frameAt(time: Double): Bitmap? = retriever.getScaledFrameAtTime(
                    (time * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, 960, 960,
                )

                val frames = mutableListOf<Frame>()
                val samples = mutableMapOf<Double, PoseSample>()
                for (i in 0 until count) {
                    currentCoroutineContext().ensureActive()
                    val time = i.toDouble() / SAMPLE_RATE
                    frameAt(time)?.let { bitmap ->
                        detector.detect(bitmap)?.let { sample ->
                            frames += Frame(time, sample.pose)
                            samples[time] = sample
                        }
                        bitmap.recycle()
                    }
                    onProgress((i + 1).toFloat() / count)
                }

                val result = ServeAnalyzer.analyze(frames, hand)
                ReviewedServe(
                    result = result,
                    trophyImage = result.trophyFrame?.let { frameAt(it.time) },
                    contactImage = result.contactFrame?.let { frameAt(it.time) },
                    trophySample = result.trophyFrame?.let { samples[it.time] },
                    contactSample = result.contactFrame?.let { samples[it.time] },
                )
            } finally {
                detector.close()
                retriever.release()
            }
        }
}

@Composable
fun VideoScreen(vm: AppViewModel, onReview: (ReviewedServe) -> Unit) {
    val context = LocalContext.current
    var uri by remember { mutableStateOf<Uri?>(null) }
    var progress by remember { mutableStateOf<Float?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { picked ->
        if (picked != null) uri = picked
    }

    LaunchedEffect(uri) {
        val picked = uri ?: return@LaunchedEffect
        message = null
        progress = 0f
        try {
            val serve = VideoAnalyzer.analyze(context, picked, vm.hand) { p -> progress = p }
            if (serve.result.trophyFrame == null && serve.result.contactFrame == null) {
                message = "No serve found. Make sure your whole body is visible and the clip includes the toss and contact."
            } else {
                vm.record(serve)
                onReview(serve)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            message = "Couldn't read that video: ${e.message}"
        } finally {
            progress = null
            uri = null
        }
    }

    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val p = progress
        if (p != null) {
            LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.padding(6.dp))
            Text("Finding your trophy position and contact point…")
        } else {
            Icon(Icons.Filled.VideoLibrary, null, Modifier.padding(8.dp))
            Text("Analyze a serve video", style = MaterialTheme.typography.titleLarge)
            Text("Film one serve side-on with your whole body in frame, then pick the clip.", textAlign = TextAlign.Center)
            Spacer(Modifier.padding(8.dp))
            Button(onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) }) {
                Text("Pick video")
            }
            message?.let {
                Spacer(Modifier.padding(8.dp))
                Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
            }
        }
    }
}
