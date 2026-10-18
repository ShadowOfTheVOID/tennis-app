import ServeAnalysis
import SwiftUI

@main
struct ServeCoachApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                LiveCoachView()
                    .tabItem { Label("Live", systemImage: "camera.viewfinder") }
                VideoAnalysisView()
                    .tabItem { Label("Video", systemImage: "film") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            // Free the AI model (up to ~2 GB) when the app goes to the background.
            if phase == .background { app.releaseModel() }
        }
    }
}
