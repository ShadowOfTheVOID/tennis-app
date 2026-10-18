package com.servecoach.app

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.servecoach.analysis.Evaluation
import com.servecoach.analysis.Frame
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.Phase
import com.servecoach.analysis.ServeAnalyzer
import com.servecoach.analysis.ServeTracker
import com.servecoach.analysis.StrokeAnalyzer
import com.servecoach.analysis.StrokeResult
import com.servecoach.analysis.StrokeTracker
import com.servecoach.analysis.StrokeType
import com.servecoach.analysis.stroke
import androidx.compose.foundation.lazy.items
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Runs pose detection on camera frames, tracks strokes, and keeps a few seconds of
 * downscaled stills so a finished stroke can be reviewed. Runs on the analysis thread.
 */
private class LiveAnalyzer(
    @Volatile var hand: Handedness,
    /** The stroke being practised; null means work it out from each swing. */
    @Volatile var stroke: StrokeType?,
    private val onSample: (PoseSample?, Evaluation?) -> Unit,
    private val onStroke: (ReviewedStroke) -> Unit,
) : ImageAnalysis.Analyzer {
    private val detector = BodyPoseDetector(stream = true)
    private var serveTracker = ServeTracker(hand)
    private var strokeTracker = StrokeTracker(hand, stroke)
    private val snapshots = ArrayDeque<Triple<Double, Bitmap, PoseSample>>()
    private var lastSnapshot = Double.NEGATIVE_INFINITY
    private var lastPublish = 0L

    @OptIn(ExperimentalGetImage::class)
    override fun analyze(proxy: ImageProxy) {
        proxy.use {
            val media = proxy.image ?: return
            val rotation = proxy.imageInfo.rotationDegrees
            val upright = rotation % 180 != 0
            val width = if (upright) proxy.height else proxy.width
            val height = if (upright) proxy.width else proxy.height
            val time = proxy.imageInfo.timestamp / 1e9
            if (serveTracker.hand != hand) serveTracker = ServeTracker(hand)
            if (strokeTracker.hand != hand || strokeTracker.type != stroke) strokeTracker = StrokeTracker(hand, stroke)

            val sample = detector.detect(InputImage.fromMediaImage(media, rotation), width, height)
            var finished: ReviewedStroke? = null
            if (sample != null) {
                if (time - lastSnapshot >= 0.1) {
                    lastSnapshot = time
                    snapshots.addLast(Triple(time, proxy.uprightBitmap(rotation), sample))
                    while (snapshots.first().first < time - 3.5) snapshots.removeFirst()
                }
                val frame = Frame(time, sample.pose)
                val result = if (stroke == StrokeType.SERVE) serveTracker.add(frame)?.stroke else strokeTracker.add(frame)
                finished = result?.let(::review)
            }
            val now = SystemClock.elapsedRealtime()
            if (finished != null || now - lastPublish > 66) {
                lastPublish = now
                // Hold-pose feedback: the serve's trophy and contact, or the ready position for other strokes.
                val live = sample?.let {
                    if (stroke == StrokeType.SERVE) ServeAnalyzer.evaluate(it.pose, hand) else StrokeAnalyzer.readyPosition(it.pose)
                }
                onSample(sample, live)
            }
            finished?.let(onStroke)
        }
    }

    /** Match a stroke's key frames to the nearest stored stills. */
    private fun review(result: StrokeResult): ReviewedStroke {
        val images = mutableMapOf<Phase, Bitmap>()
        val samples = mutableMapOf<Phase, PoseSample>()
        for (key in result.keyFrames) {
            val nearest = snapshots.minByOrNull { kotlin.math.abs(it.first - key.frame.time) } ?: continue
            images[key.phase] = nearest.second
            samples[key.phase] = nearest.third
        }
        snapshots.removeAll { it.first <= result.time + 0.5 }
        return ReviewedStroke(result, images, samples)
    }

    fun close() = detector.close()
}

/** The frame as an upright, half-resolution bitmap. */
private fun ImageProxy.uprightBitmap(rotation: Int): Bitmap {
    val source = toBitmap()
    val matrix = Matrix().apply {
        postRotate(rotation.toFloat())
        postScale(0.5f, 0.5f)
    }
    return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
}

@Composable
fun LiveScreen(vm: AppViewModel, onReview: (ReviewedStroke) -> Unit) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }

    if (!granted) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Camera access needed", style = MaterialTheme.typography.titleLarge)
            Text("Serve Coach watches your body position while you play. Video never leaves your phone.", textAlign = TextAlign.Center)
            Spacer(Modifier.padding(8.dp))
            Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) { Text("Allow camera") }
        }
        return
    }

    var front by remember { mutableStateOf(false) }
    var sample by remember { mutableStateOf<PoseSample?>(null) }
    var live by remember { mutableStateOf<Evaluation?>(null) }
    var lastStroke by remember { mutableStateOf<ReviewedStroke?>(null) }
    var strokeCount by remember { mutableIntStateOf(0) }
    var holdMode by remember { mutableStateOf(false) }
    val currentVm by rememberUpdatedState(vm)

    val tts = remember { mutableStateOf<TextToSpeech?>(null) }
    DisposableEffect(Unit) {
        var engine: TextToSpeech? = null
        engine = TextToSpeech(context) { status -> if (status == TextToSpeech.SUCCESS) engine?.language = Locale.getDefault() }
        tts.value = engine
        onDispose { engine.shutdown() }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val analyzer = remember {
        LiveAnalyzer(
            hand = vm.hand,
            stroke = vm.practiceStroke,
            onSample = { s, e ->
                previewView.post {
                    sample = s
                    if (e != null) live = e
                }
            },
            onStroke = { stroke ->
                previewView.post {
                    lastStroke = stroke
                    strokeCount++
                    currentVm.record(stroke)
                    if (currentVm.spokenCues) {
                        val score = stroke.result.score?.let { "${stroke.result.title}, $it. " } ?: ""
                        val tip = stroke.result.topTip?.tip ?: "Great ${stroke.result.title.lowercase()}!"
                        tts.value?.speak(score + tip, TextToSpeech.QUEUE_FLUSH, null, stroke.id)
                    }
                }
            },
        )
    }
    analyzer.hand = vm.hand
    analyzer.stroke = vm.practiceStroke

    DisposableEffect(front) {
        val executor = Executors.newSingleThreadExecutor()
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                .build()
                .also { it.setAnalyzer(executor, analyzer) }
            val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            provider.unbindAll()
            runCatching { provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis) }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            runCatching { providerFuture.get().unbindAll() }
            executor.shutdown()
        }
    }
    DisposableEffect(Unit) { onDispose { analyzer.close() } }

    val phaseColor = when (sample?.takeIf { vm.practiceStroke == StrokeType.SERVE }?.let { ServeAnalyzer.phase(it.pose, vm.hand) }) {
        Phase.TROPHY -> Color.Yellow
        Phase.CONTACT -> Color.Cyan
        else -> Color.Green
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView({ previewView }, Modifier.fillMaxSize())
        SkeletonOverlay(sample, Modifier.fillMaxSize(), fill = true, mirrored = front, color = phaseColor)

        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f))) {
                Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    HandPicker(vm.hand, vm::updateHand, Modifier.weight(1f))
                    Spacer(Modifier.width(8.dp))
                    FilledTonalIconButton(onClick = { front = !front }) { Icon(Icons.Filled.Cameraswitch, "Switch camera") }
                }
                StrokePicker(vm.practiceStroke, vm::updatePracticeStroke, Modifier.padding(start = 8.dp, end = 8.dp, bottom = 8.dp))
            }
            Spacer(Modifier.weight(1f))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                SegmentedButton(!holdMode, { holdMode = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Last stroke") }
                SegmentedButton(holdMode, { holdMode = true }, SegmentedButtonDefaults.itemShape(1, 2)) {
                    Text(if (vm.practiceStroke == StrokeType.SERVE) "Hold pose" else "Ready position")
                }
            }
            Spacer(Modifier.padding(4.dp))
            Column(Modifier.fillMaxWidth().heightIn(max = 340.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val stroke = lastStroke
                when {
                    holdMode -> live?.let { EvaluationCard(it) } ?: Hint(
                        if (vm.practiceStroke == StrokeType.SERVE) "Raise your tossing arm into the trophy position and hold it."
                        else "Get into your ready position: knees bent, feet wide, racket up in front."
                    )
                    stroke != null -> {
                        Card(Modifier.fillMaxWidth()) {
                            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("${stroke.result.title} #$strokeCount", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                                Button(onClick = { onReview(stroke) }) {
                                    Icon(Icons.Filled.AutoAwesome, null)
                                    Spacer(Modifier.width(4.dp))
                                    Text("AI coach")
                                }
                                Spacer(Modifier.width(8.dp))
                                ScoreBadge(stroke.result.score)
                            }
                        }
                        stroke.result.evaluations.forEach { EvaluationCard(it) }
                    }
                    else -> Hint("Set the phone up side-on, about 4 m away, with your whole body in frame. Then hit!")
                }
            }
        }
    }
}

@Composable
fun Hint(text: String) {
    Card(Modifier.fillMaxWidth()) {
        Text(text, Modifier.padding(16.dp).fillMaxWidth(), textAlign = TextAlign.Center)
    }
}

/** Serve, Forehand, ... or Any (worked out from each swing). */
@Composable
fun StrokePicker(selected: StrokeType?, onChange: (StrokeType?) -> Unit, modifier: Modifier = Modifier) {
    androidx.compose.foundation.lazy.LazyRow(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items(listOf<StrokeType?>(null) + StrokeType.entries) { type ->
            androidx.compose.material3.FilterChip(
                selected = selected == type,
                onClick = { onChange(type) },
                label = { Text(type?.title ?: "Any") },
            )
        }
    }
}

@Composable
fun HandPicker(hand: Handedness, onChange: (Handedness) -> Unit, modifier: Modifier = Modifier) {
    SingleChoiceSegmentedButtonRow(modifier) {
        SegmentedButton(hand == Handedness.RIGHT, { onChange(Handedness.RIGHT) }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Righty") }
        SegmentedButton(hand == Handedness.LEFT, { onChange(Handedness.LEFT) }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Lefty") }
    }
}
