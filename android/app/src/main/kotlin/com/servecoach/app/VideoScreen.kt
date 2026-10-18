package com.servecoach.app

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
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
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.servecoach.analysis.Frame
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.MatchAnalyzer
import com.servecoach.analysis.Phase
import com.servecoach.analysis.StrokeAnalyzer
import com.servecoach.analysis.StrokeResult
import com.servecoach.analysis.StrokeType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

object VideoAnalyzer {
    /** A single stroke: dense sampling, the accurate pose model, up to 20 s. */
    private const val STROKE_FPS = 15
    private const val STROKE_MAX_SECONDS = 20
    /** A match: lighter sampling and the fast pose model, up to 10 minutes. */
    private const val MATCH_FPS = 10
    const val MATCH_MAX_SECONDS = 600

    /** Analyse a clip of one stroke. Null if no stroke was found. */
    suspend fun analyzeStroke(context: Context, uri: Uri, hand: Handedness, type: StrokeType?, onProgress: (Float) -> Unit): ReviewedStroke? =
        withContext(Dispatchers.Default) {
            val (frames, samples) = poses(context, uri, STROKE_FPS, STROKE_MAX_SECONDS, fast = false, onProgress)
            val result = StrokeAnalyzer.analyzeClip(frames, type, hand) ?: return@withContext null
            stills(context, uri, result, samples)
        }

    suspend fun analyzeMatch(context: Context, uri: Uri, hand: Handedness, onProgress: (Float) -> Unit): AnalyzedMatch =
        withContext(Dispatchers.Default) {
            val (frames, samples) = poses(context, uri, MATCH_FPS, MATCH_MAX_SECONDS, fast = true, onProgress)
            AnalyzedMatch(MatchAnalyzer.analyze(frames, hand), uri, samples)
        }

    /** Pull the stills for one stroke's key moments from the video. */
    suspend fun stills(context: Context, uri: Uri, result: StrokeResult, samples: Map<Double, PoseSample>): ReviewedStroke =
        withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, uri)
                val images = mutableMapOf<Phase, Bitmap>()
                val poseSamples = mutableMapOf<Phase, PoseSample>()
                for (key in result.keyFrames) {
                    retriever.getScaledFrameAtTime((key.frame.time * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, 960, 960)
                        ?.let { images[key.phase] = it }
                    samples[key.frame.time]?.let { poseSamples[key.phase] = it }
                }
                // Every analysed frame around the stroke, smaller, for the slow-motion replay.
                val from = (result.keyFrames.minOfOrNull { it.frame.time } ?: result.time) - 0.3
                val to = (result.keyFrames.maxOfOrNull { it.frame.time } ?: result.time) + 0.3
                val replay = samples.keys.filter { it in from..to }.sorted().take(60).mapNotNull { t ->
                    retriever.getScaledFrameAtTime((t * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, 540, 540)
                        ?.let { ReplayFrame(t, it, samples[t]) }
                }
                ReviewedStroke(result, images, poseSamples, replay)
            } finally {
                retriever.release()
            }
        }

    /** Detect a pose in every sampled frame. Returns the frames and the pose samples by time. */
    private suspend fun poses(
        context: Context, uri: Uri, fps: Int, maxSeconds: Int, fast: Boolean, onProgress: (Float) -> Unit,
    ): Pair<List<Frame>, Map<Double, PoseSample>> {
        val retriever = MediaMetadataRetriever()
        val detector = BodyPoseDetector(stream = false, fast = fast)
        val frames = mutableListOf<Frame>()
        val samples = mutableMapOf<Double, PoseSample>()
        fun add(time: Double, bitmap: Bitmap) {
            val small = bitmap.scaledToMax(if (fast) 640 else 960)
            detector.detect(small)?.let {
                frames += Frame(time, it.pose)
                samples[time] = it
            }
            if (small !== bitmap) small.recycle()
            bitmap.recycle()
        }
        try {
            retriever.setDataSource(context, uri)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val seconds = min(durationMs / 1000.0, maxSeconds.toDouble())
            val frameCount = if (Build.VERSION.SDK_INT >= 28) {
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull() ?: 0
            } else 0

            if (Build.VERSION.SDK_INT >= 28 && frameCount > 0 && durationMs > 0) {
                // Decode consecutive frames in batches: much faster than seeking to each one.
                val videoFps = frameCount / (durationMs / 1000.0)
                val step = max(1, (videoFps / fps).roundToInt())
                val last = min(frameCount, (seconds * videoFps).toInt())
                var index = 0
                while (index < last) {
                    currentCoroutineContext().ensureActive()
                    val count = min(6, last - index)
                    val batch = runCatching { retriever.getFramesAtIndex(index, count) }.getOrNull() ?: break
                    batch.forEachIndexed { k, bitmap ->
                        if ((index + k) % step == 0) add((index + k) / videoFps, bitmap) else bitmap.recycle()
                    }
                    index += count
                    onProgress(index.toFloat() / last)
                }
            } else {
                val count = max(1, (seconds * fps).toInt())
                for (i in 0 until count) {
                    currentCoroutineContext().ensureActive()
                    val time = i.toDouble() / fps
                    retriever.getScaledFrameAtTime((time * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, 960, 960)
                        ?.let { add(time, it) }
                    onProgress((i + 1).toFloat() / count)
                }
            }
        } finally {
            detector.close()
            retriever.release()
        }
        return frames to samples
    }
}

@Composable
fun VideoScreen(vm: AppViewModel, onReview: (ReviewedStroke) -> Unit, onMatch: (AnalyzedMatch) -> Unit) {
    val context = LocalContext.current
    var matchMode by rememberSaveable { mutableStateOf(false) }
    var strokeType by remember { mutableStateOf<StrokeType?>(null) }
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
            if (matchMode) {
                val match = VideoAnalyzer.analyzeMatch(context, picked, vm.hand) { p -> progress = p }
                if (match.report.strokes.isEmpty()) {
                    message = "No strokes found. Film from the side with your whole body in frame, and keep the camera still."
                } else {
                    vm.record(match)
                    onMatch(match)
                }
            } else {
                val stroke = VideoAnalyzer.analyzeStroke(context, picked, vm.hand, strokeType) { p -> progress = p }
                if (stroke == null) {
                    message = "No stroke found. Make sure your whole body is visible and the clip includes the whole swing."
                } else {
                    vm.record(stroke)
                    onReview(stroke)
                }
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
            Text(if (matchMode) "Finding every stroke… long matches take a few minutes." else "Finding your stroke's key moments…", textAlign = TextAlign.Center)
            TextButton(onClick = { uri = null }) { Text("Cancel") }
        } else {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                SegmentedButton(!matchMode, { matchMode = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("One stroke") }
                SegmentedButton(matchMode, { matchMode = true }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Match") }
            }
            Spacer(Modifier.padding(12.dp))
            Icon(Icons.Filled.VideoLibrary, null, Modifier.padding(8.dp))
            if (matchMode) {
                Text("Analyze a match or rally", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Film from the side of the court with your whole body in frame. Up to ${VideoAnalyzer.MATCH_MAX_SECONDS / 60} minutes. " +
                        "You'll get every stroke graded, footwork and movement, and a match plan.",
                    textAlign = TextAlign.Center,
                )
            } else {
                Text("Analyze one stroke", style = MaterialTheme.typography.titleLarge)
                Text("Film one stroke side-on with your whole body in frame, then pick the clip.", textAlign = TextAlign.Center)
                Spacer(Modifier.padding(6.dp))
                StrokePicker(strokeType, { strokeType = it })
            }
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
