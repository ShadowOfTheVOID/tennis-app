package com.servecoach.wear

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import com.google.android.gms.wearable.Wearable
import com.servecoach.analysis.MotionSample
import com.servecoach.analysis.WatchSummary
import com.servecoach.analysis.WristSwing
import com.servecoach.analysis.WristSwingDetector
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.Json
import kotlin.math.roundToInt

/** Wear it on your hitting wrist: counts swings and measures wrist speed, then sends the session to the phone. */
class WatchActivity : ComponentActivity(), SensorEventListener {
    private lateinit var sensors: SensorManager
    private var detector = WristSwingDetector()
    private val swings = mutableListOf<WristSwing>()
    private var accel = FloatArray(3)
    private var started = 0L

    private var running by mutableStateOf(false)
    private var count by mutableIntStateOf(0)
    private var last by mutableStateOf<WristSwing?>(null)
    private var status by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sensors = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        setContent {
            val scope = rememberCoroutineScope()
            MaterialTheme {
                Column(
                    Modifier.fillMaxSize().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (running) {
                        Text("$count swings", style = MaterialTheme.typography.titleLarge)
                        last?.let { Text("Last: %,d°/s".format(it.peakRotation.roundToInt()), style = MaterialTheme.typography.bodyMedium) }
                        Button(onClick = { scope.launch { stop() } }) { Text("Finish") }
                    } else {
                        Text("Serve Coach", style = MaterialTheme.typography.titleMedium)
                        Text(status ?: "Wear on your hitting wrist, then start.", textAlign = TextAlign.Center,
                            style = MaterialTheme.typography.bodySmall)
                        Button(onClick = { start() }) { Text("Start") }
                    }
                }
            }
        }
        lifecycleScope.launch { sendPending() }
    }

    private fun start() {
        detector = WristSwingDetector()
        swings.clear()
        count = 0
        last = null
        status = null
        started = System.currentTimeMillis()
        // 100 Hz: enough to catch the peak of a swing without the high-rate sensor permission.
        sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let { sensors.registerListener(this, it, 10_000) }
        sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let { sensors.registerListener(this, it, 10_000) }
        // Keep the screen (and so the session) awake while practising.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        running = true
    }

    private suspend fun stop() {
        sensors.unregisterListener(this)
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        running = false
        val seconds = (System.currentTimeMillis() - started) / 1000.0
        val summary = WatchSummary.of(swings.toList(), seconds, started)
        status = "${summary.swings} swings. ${summary.verdict}."
        savePending(this, pending(this) + Json.encodeToString(WatchSummary.serializer(), summary))
        sendPending()
    }

    /** Send every unsent session to the phone; keep any that couldn't be sent for next time. */
    private suspend fun sendPending() {
        val queue = pending(this)
        if (queue.isEmpty()) return
        val nodes = runCatching { Wearable.getNodeClient(this).connectedNodes.await() }.getOrDefault(emptyList())
        if (nodes.isEmpty()) {
            status = (status?.let { "$it " } ?: "") + "Will send to your phone when it's connected."
            return
        }
        val client = Wearable.getMessageClient(this)
        val sent = queue.filter { json ->
            nodes.any { node -> runCatching { client.sendMessage(node.id, WatchSummary.PATH, json.encodeToByteArray()).await() }.isSuccess }
        }
        queue.removeAll(sent.toSet())
        savePending(this, queue)
        if (sent.isNotEmpty()) status = (status?.let { "$it " } ?: "") + "Saved to your phone."
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> accel = event.values.clone()
            Sensor.TYPE_GYROSCOPE -> {
                val g = SensorManager.GRAVITY_EARTH
                val sample = MotionSample(
                    event.timestamp / 1e9,
                    accel[0] / g.toDouble(), accel[1] / g.toDouble(), accel[2] / g.toDouble(),
                    event.values[0].toDouble(), event.values[1].toDouble(), event.values[2].toDouble(),
                )
                detector.add(sample)?.let { swings += it; count = swings.size; last = it }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit

    override fun onDestroy() {
        sensors.unregisterListener(this)
        super.onDestroy()
    }

    private companion object {
        fun prefs(context: Context) = context.getSharedPreferences("sessions", Context.MODE_PRIVATE)

        fun pending(context: Context): MutableList<String> {
            val raw = prefs(context).getString("pending", null) ?: return mutableListOf()
            return runCatching { Json.decodeFromString<List<String>>(raw).toMutableList() }.getOrDefault(mutableListOf())
        }

        fun savePending(context: Context, queue: List<String>) =
            prefs(context).edit().putString("pending", Json.encodeToString(queue)).apply()
    }
}
