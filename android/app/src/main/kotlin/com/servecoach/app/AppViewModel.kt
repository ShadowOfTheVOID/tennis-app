package com.servecoach.app

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
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
import com.servecoach.analysis.MatchReport
import com.servecoach.analysis.Phase
import com.servecoach.analysis.PracticeRecord
import com.servecoach.analysis.PracticeStats
import com.servecoach.analysis.StrokeResult
import com.servecoach.analysis.StrokeType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** One frame of a stroke's slow-motion replay. */
data class ReplayFrame(val time: Double, val image: Bitmap, val sample: PoseSample?)

/** A completed stroke with stills of its key moments, kept together for review and AI coaching. */
data class ReviewedStroke(
    val result: StrokeResult,
    val images: Map<Phase, Bitmap>,
    val samples: Map<Phase, PoseSample>,
    /** Frames around the stroke, oldest first, for frame-by-frame replay. */
    val replay: List<ReplayFrame> = emptyList(),
    /** Also the id of its history record, so "compare with your best" can skip this stroke. */
    val id: String = UUID.randomUUID().toString(),
)

/**
 * An analysed match video. Stills for each stroke are pulled from the video only when a
 * stroke is opened, so long videos don't fill memory.
 */
data class AnalyzedMatch(
    val report: MatchReport,
    val video: Uri,
    /** Pose at every analysed frame, by time, for skeletons and replays. */
    val samples: Map<Double, PoseSample>,
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
    /** The stroke being practised on the Live tab; null means work it out from each swing. */
    var practiceStroke by mutableStateOf(prefs.getString("stroke", StrokeType.SERVE.name)?.let { name ->
        StrokeType.entries.firstOrNull { it.name == name }
    })
        private set
    var preferredModelId by mutableStateOf(prefs.getString("model", null))
        private set
    var history by mutableStateOf(emptyList<PracticeRecord>())
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

    fun updatePracticeStroke(value: StrokeType?) {
        practiceStroke = value
        prefs.edit().putString("stroke", value?.name ?: "ANY").apply()
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

    /** Save a finished stroke to history. */
    fun record(stroke: ReviewedStroke) = save(PracticeRecord.of(stroke.result, hand).copy(id = stroke.id))

    /** Your best saved stroke of the same kind, other than [stroke] itself. */
    fun bestFor(stroke: ReviewedStroke): PracticeRecord? =
        PracticeStats.best(history.filter { it.id != stroke.id }, stroke.result.type.key)

    /** Save an analysed match to history. */
    fun record(match: AnalyzedMatch) = save(PracticeRecord.of(match.report, hand))

    private fun save(record: PracticeRecord) {
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

    fun requestCoaching(stroke: ReviewedStroke) = coachInBackground(stroke.id) { coach.review(stroke, hand, preferredModel) }

    fun requestCoaching(match: AnalyzedMatch) = coachInBackground(match.id) { coach.review(match.report, hand, preferredModel) }

    private fun coachInBackground(id: String, work: suspend () -> CoachReport) {
        if (coaching[id] == true) return
        coaching[id] = true
        viewModelScope.launch {
            try {
                reports[id] = work()
            } finally {
                coaching.remove(id)
            }
        }
    }

    fun releaseModel() = coach.release()

    override fun onCleared() = coach.release()
}
