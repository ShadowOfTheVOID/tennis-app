package com.servecoach.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector

private enum class Tab(val title: String, val icon: ImageVector) {
    LIVE("Live", Icons.Filled.Videocam),
    VIDEO("Video", Icons.Filled.VideoLibrary),
    HISTORY("History", Icons.Filled.History),
    SETTINGS("Settings", Icons.Filled.Settings),
}

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val green = Color(0xFF1B6B3A)
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme(primary = Color(0xFF7FD69B)) else lightColorScheme(primary = green)) {
                var tab by rememberSaveable { mutableStateOf(Tab.LIVE) }
                // Screens opened on top of the tabs: a match report, then a stroke review from it.
                val stack = remember { mutableStateListOf<Any>() }
                val top = stack.lastOrNull()
                BackHandler(enabled = top != null) { stack.removeAt(stack.lastIndex) }

                Scaffold(
                    topBar = {
                        if (top != null) {
                            TopAppBar(
                                title = { Text(if (top is AnalyzedMatch) "Match report" else "Stroke review") },
                                navigationIcon = {
                                    IconButton(onClick = { stack.removeAt(stack.lastIndex) }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                                },
                            )
                        } else if (tab != Tab.LIVE) {
                            TopAppBar(title = { Text(tab.title) })
                        }
                    },
                    bottomBar = {
                        if (top == null) {
                            NavigationBar {
                                Tab.entries.forEach { t ->
                                    NavigationBarItem(
                                        selected = tab == t,
                                        onClick = { tab = t },
                                        icon = { Icon(t.icon, null) },
                                        label = { Text(t.title) },
                                    )
                                }
                            }
                        }
                    },
                ) { padding ->
                    val modifier = Modifier.padding(padding)
                    androidx.compose.foundation.layout.Box(modifier) {
                        when {
                            top is ReviewedStroke -> ReviewScreen(vm, top)
                            top is AnalyzedMatch -> MatchScreen(vm, top) { stack.add(it) }
                            tab == Tab.LIVE -> LiveScreen(vm) { stack.add(it) }
                            tab == Tab.VIDEO -> VideoScreen(vm, onReview = { stack.add(it) }, onMatch = { stack.add(it) })
                            tab == Tab.HISTORY -> HistoryScreen(vm)
                            else -> SettingsScreen(vm)
                        }
                    }
                }
            }
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // Free the AI model (up to ~2 GB) when the app is in the background.
        if (level >= TRIM_MEMORY_UI_HIDDEN) vm.releaseModel()
    }
}
