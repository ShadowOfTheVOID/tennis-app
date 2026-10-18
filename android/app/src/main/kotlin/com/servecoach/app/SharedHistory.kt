package com.servecoach.app

import android.content.Context
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.HistoryStore
import com.servecoach.analysis.PracticeRecord
import com.servecoach.analysis.WatchSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import java.io.File

/** One history store per process, shared by the screens, reminders and the watch listener. */
object SharedHistory {
    @Volatile private var store: HistoryStore? = null
    private val _changes = MutableStateFlow(0)
    /** Bumped whenever a record is added from outside the app's screens. */
    val changes: StateFlow<Int> get() = _changes

    fun store(context: Context): HistoryStore = store ?: synchronized(this) {
        store ?: HistoryStore(File(context.applicationContext.filesDir, "history.json")).also { store = it }
    }

    fun add(context: Context, record: PracticeRecord) {
        store(context).add(record)
        _changes.value++
    }
}

/** Saves a practice session sent from the Wear OS app. */
class WatchSessionService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WatchSummary.PATH) return
        val summary = runCatching { Json.decodeFromString<WatchSummary>(event.data.decodeToString()) }.getOrNull() ?: return
        val prefs = getSharedPreferences("settings", Context.MODE_PRIVATE)
        val hand = Handedness.valueOf(prefs.getString("hand", Handedness.RIGHT.name)!!)
        SharedHistory.add(this, PracticeRecord.of(summary, hand))
    }
}
