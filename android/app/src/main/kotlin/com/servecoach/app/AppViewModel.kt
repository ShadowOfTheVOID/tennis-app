package com.servecoach.app

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.servecoach.analysis.CoachModel
import com.servecoach.analysis.CoachReport
import com.servecoach.analysis.Handedness
import com.servecoach.analysis.HistoryStore
import com.servecoach.analysis.ServeRecord
import com.servecoach.analysis.ServeResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** A completed serve's key frames, kept together for review and AI coaching. */
data class ReviewedServe(
    val result: ServeResult,
    val trophyImage: Bitmap?,
    val contactImage: Bitmap?,
    val trophySample: PoseSample?,
    val contactSample: PoseSample?,
    val id: String = UUID.randomUUID().toString(),
)

sealed interface DownloadState {
    data class Running(val progress: Float) : DownloadState
    data class Failed(val message: String) : DownloadState
}

/** App-wide state: settings, history, AI models and coaching. */
class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)
    val models = ModelManager(app)
    private val coach = AiCoach(app, models)
    private val historyStore = HistoryStore(File(app.filesDir, "history.json"))

    var hand by mutableStateOf(Handedness.valueOf(prefs.getString("hand", Handedness.RIGHT.name)!!))
        private set
    var spokenCues by mutableStateOf(prefs.getBoolean("spokenCues", true))
        private set
    var preferredModelId by mutableStateOf(prefs.getString("model", null))
        private set
    var history by mutableStateOf(emptyList<ServeRecord>())
        private set

    /** Bumped when a model is installed or deleted so the UI re-reads install state. */
    var modelsVersion by mutableStateOf(0)
        private set
    val downloads = mutableStateMapOf<String, DownloadState>()
    private val downloadJobs = mutableMapOf<String, Job>()

    /** Coaching reports already produced, by serve id, so reopening a review doesn't re-run the model. */
    val reports = mutableStateMapOf<String, CoachReport>()
    val coaching = mutableStateMapOf<String, Boolean>()

    init {
        viewModelScope.launch { history = withContext(Dispatchers.IO) { historyStore.records } }
    }

    fun updateHand(value: Handedness) {
        hand = value
        prefs.edit().putString("hand", value.name).apply()
    }

    fun updateSpokenCues(value: Boolean) {
        spokenCues = value
        prefs.edit().putBoolean("spokenCues", value).apply()
    }

    fun selectModel(model: CoachModel) {
        preferredModelId = model.id
        prefs.edit().putString("model", model.id).apply()
    }

    val preferredModel: CoachModel? get() = CoachModel.ALL.firstOrNull { it.id == preferredModelId }

    /** The model the coach will use right now, or null for the built-in coach. */
    val activeModel: CoachModel? get() = modelsVersion.let { coach.activeModel(preferredModel) }

    fun isInstalled(model: CoachModel) = modelsVersion.let { models.isInstalled(model) }

    fun download(model: CoachModel) {
        if (downloadJobs[model.id]?.isActive == true) return
        downloads[model.id] = DownloadState.Running(0f)
        downloadJobs[model.id] = viewModelScope.launch {
            try {
                models.download(model) { p -> viewModelScope.launch { downloads[model.id] = DownloadState.Running(p) } }
                downloads.remove(model.id)
                if (preferredModelId == null) selectModel(model)
                modelsVersion++
            } catch (e: kotlinx.coroutines.CancellationException) {
                downloads.remove(model.id)
                throw e
            } catch (e: Exception) {
                downloads[model.id] = DownloadState.Failed(e.message ?: "Download failed.")
            }
        }
    }

    fun cancelDownload(model: CoachModel) {
        downloadJobs.remove(model.id)?.cancel()
        downloads.remove(model.id)
    }

    fun deleteModel(model: CoachModel) {
        coach.release()
        models.delete(model)
        modelsVersion++
    }

    /** Save a finished serve to history. */
    fun record(serve: ReviewedServe) {
        val record = ServeRecord.of(serve.result, hand)
        viewModelScope.launch {
            withContext(Dispatchers.IO) { historyStore.add(record) }
            history = listOf(record) + history
        }
    }

    fun clearHistory() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { historyStore.clear() }
            history = emptyList()
        }
    }

    fun requestCoaching(serve: ReviewedServe) {
        if (coaching[serve.id] == true) return
        coaching[serve.id] = true
        viewModelScope.launch {
            try {
                reports[serve.id] = coach.review(serve, hand, preferredModel)
            } finally {
                coaching.remove(serve.id)
            }
        }
    }

    fun releaseModel() = coach.release()

    override fun onCleared() = coach.release()
}
