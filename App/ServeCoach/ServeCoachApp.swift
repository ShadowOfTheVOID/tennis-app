import ServeAnalysis
import SwiftUI

@main
struct ServeCoachApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                LiveCoachView()
                    .tabItem { Label("Live", systemImage: "camera.viewfinder") }
                VideoAnalysisView()
                    .tabItem { Label("Video", systemImage: "film") }
            }
        }
    }
}
