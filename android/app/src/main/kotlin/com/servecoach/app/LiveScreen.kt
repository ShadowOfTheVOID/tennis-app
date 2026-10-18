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
import com.servecoach.analysis.ServeResult
import com.servecoach.analysis.ServeTracker
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Runs pose detection on camera frames, tracks serves, and keeps a few seconds of
 * downscaled stills so a finished serve can be reviewed. Runs on the analysis thread.
 */
private class LiveAnalyzer(
    @Volatile var hand: Handedness,
    private val onSample: (PoseSample?, Evaluation?) -> Unit,
    private val onServe: (ReviewedServe) -> Unit,
) : ImageAnalysis.Analyzer {
    private val detector = BodyPoseDetector(stream = true)
    private var tracker = ServeTracker(hand)
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
            if (tracker.hand != hand) tracker = ServeTracker(hand)

            val sample = detector.detect(InputImage.fromMediaImage(media, rotation), width, height)
            var serve: ReviewedServe? = null
            if (sample != null) {
                if (time - lastSnapshot >= 0.1) {
                    lastSnapshot = time
                    snapshots.addLast(Triple(time, proxy.uprightBitmap(rotation), sample))
                    while (snapshots.first().first < time - tracker.window) snapshots.removeFirst()
                }
                serve = tracker.add(Frame(time, sample.pose))?.let(::review)
            }
            val now = SystemClock.elapsedRealtime()
            if (serve != null || now - lastPublish > 66) {
                lastPublish = now
                onSample(sample, sample?.let { ServeAnalyzer.evaluate(it.pose, hand) })
            }
            serve?.let(onServe)
        }
    }

    /** Match a serve's key frames to the nearest stored stills. */
    private fun review(result: ServeResult): ReviewedServe {
        fun nearest(frame: Frame?) = frame?.let { f -> snapshots.minByOrNull { kotlin.math.abs(it.first - f.time) } }
        val trophy = nearest(result.trophyFrame)
        val contact = nearest(result.contactFrame)
        snapshots.clear()
        return ReviewedServe(result, trophy?.second, contact?.second, trophy?.third, contact?.third)
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
fun LiveScreen(vm: AppViewModel, onReview: (ReviewedServe) -> Unit) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }

    if (!granted) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Camera access needed", style = MaterialTheme.typography.titleLarge)
            Text("Serve Coach watches your body position while you serve. Video never leaves your phone.", textAlign = TextAlign.Center)
            Spacer(Modifier.padding(8.dp))
            Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) { Text("Allow camera") }
        }
        return
    }

    var front by remember { mutableStateOf(false) }
    var sample by remember { mutableStateOf<PoseSample?>(null) }
    var live by remember { mutableStateOf<Evaluation?>(null) }
    var lastServe by remember { mutableStateOf<ReviewedServe?>(null) }
    var serveCount by remember { mutableIntStateOf(0) }
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
            onSample = { s, e ->
                previewView.post {
                    sample = s
                    if (e != null) live = e
                }
            },
            onServe = { serve ->
                previewView.post {
                    lastServe = serve
                    serveCount++
                    currentVm.record(serve)
                    if (currentVm.spokenCues) {
                        val score = serve.result.score?.let { "Score $it. " } ?: ""
                        val tip = serve.result.topTip?.tip ?: "Great serve posture!"
                        tts.value?.speak(score + tip, TextToSpeech.QUEUE_FLUSH, null, serve.id)
                    }
                }
            },
        )
    }
    analyzer.hand = vm.hand

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

    val phaseColor = when (sample?.let { ServeAnalyzer.phase(it.pose, vm.hand) }) {
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
            }
            Spacer(Modifier.weight(1f))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                SegmentedButton(!holdMode, { holdMode = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Last serve") }
                SegmentedButton(holdMode, { holdMode = true }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Hold pose") }
            }
            Spacer(Modifier.padding(4.dp))
            Column(Modifier.fillMaxWidth().heightIn(max = 340.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val serve = lastServe
                when {
                    holdMode -> live?.let { EvaluationCard(it) } ?: Hint("Raise your tossing arm into the trophy position and hold it.")
                    serve != null -> {
                        Card(Modifier.fillMaxWidth()) {
                            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("Serve #$serveCount", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                                Button(onClick = { onReview(serve) }) {
                                    Icon(Icons.Filled.AutoAwesome, null)
                                    Spacer(Modifier.width(4.dp))
                                    Text("AI coach")
                                }
                                Spacer(Modifier.width(8.dp))
                                ScoreBadge(serve.result.score)
                            }
                        }
                        serve.result.trophy?.let { EvaluationCard(it) }
                        serve.result.contact?.let { EvaluationCard(it) }
                    }
                    else -> Hint("Set the phone up side-on, about 4 m away, with your whole body in frame. Then serve!")
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

@Composable
fun HandPicker(hand: Handedness, onChange: (Handedness) -> Unit, modifier: Modifier = Modifier) {
    SingleChoiceSegmentedButtonRow(modifier) {
        SegmentedButton(hand == Handedness.RIGHT, { onChange(Handedness.RIGHT) }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Righty") }
        SegmentedButton(hand == Handedness.LEFT, { onChange(Handedness.LEFT) }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Lefty") }
    }
}
