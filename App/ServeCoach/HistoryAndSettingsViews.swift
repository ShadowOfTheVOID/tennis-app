import ServeAnalysis
import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var app
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if app.history.isEmpty {
                    ContentUnavailableView(
                        "No serves yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Serves you record live or analyze from video show up here so you can track progress.")
                    )
                } else {
                    List {
                        Section { summary }
                        Section("Serves") {
                            ForEach(app.history) { record in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.date, format: .dateTime.day().month().hour().minute()).font(.subheadline.weight(.semibold))
                                        Text("Trophy \(record.trophyScore.map(String.init) ?? "—") · Contact \(record.contactScore.map(String.init) ?? "—")")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let fix = record.topFix { Text("Fix: \(fix)").font(.caption) }
                                    }
                                    Spacer()
                                    ScoreBadge(score: record.score)
                                }
                            }
                        }
                        Section {
                            Button("Clear history", role: .destructive) { confirmClear = true }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { app.clearHistory() }
            } message: {
                Text("This deletes every saved serve from this iPhone.")
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let scores = app.history.compactMap(\.score)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(app.history.count) serves").font(.headline)
            if !scores.isEmpty {
                let recent = scores.prefix(10)
                Text("Average score: \(recent.reduce(0, +) / recent.count) (last \(recent.count))")
            }
            if let trend = HistoryStats.trend(app.history) {
                Text(trend > 0 ? "Trending up: +\(trend) points over your last 5 serves"
                     : trend < 0 ? "Trending down: \(trend) points over your last 5 serves"
                     : "Holding steady over your last 5 serves")
                    .foregroundStyle(trend >= 0 ? .green : .orange)
            }
            if let fix = HistoryStats.mostCommonFix(app.history) {
                Text("Most common fix: \(fix)").fontWeight(.medium)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("handedness") private var hand: Handedness = .right
    @AppStorage("spokenCues") private var spokenCues = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Player") {
                    Picker("Hand", selection: $hand) {
                        Text("Right-handed").tag(Handedness.right)
                        Text("Left-handed").tag(Handedness.left)
                    }
                    Toggle("Spoken tips after each serve", isOn: $spokenCues)
                }

                Section {
                    ForEach(CoachModel.all) { ModelRow(model: $0) }
                } header: {
                    Text("AI coach")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var footer: String {
        let models = app.models
        var text = "Download the free AI model once and it runs entirely on your iPhone: no account, no API key, works offline. "
        text += String(format: "This iPhone: %.1f GB RAM, %.1f GB free. ", Double(models.deviceRAM) / 1e9, Double(models.freeBytes) / 1e9)
        if models.recommended == nil {
            text += "That's below what the AI model needs, so the built-in coach is used."
        } else if AppleIntelligenceCoach.isAvailable {
            text += "Without a download, Apple Intelligence coaches you from the measurements."
        } else {
            text += "Without a download you still get the built-in coach."
        }
        return text
    }
}

private struct ModelRow: View {
    let model: CoachModel
    @Environment(AppState.self) private var app
    @State private var confirmDelete = false

    var body: some View {
        let store = app.models
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.name).fontWeight(.semibold)
                if store.recommended == model { Text("Recommended").font(.caption).foregroundStyle(.green) }
                Spacer()
                Text(String(format: "%.1f GB", Double(model.sizeBytes) / 1e9)).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.summary).font(.caption).foregroundStyle(.secondary)

            switch store.downloads[model.id] {
            case .running(let progress):
                ProgressView(value: progress)
                HStack {
                    Text("Downloading… \(Int(progress * 100))%. Keep the app open; Wi-Fi recommended.").font(.caption)
                    Spacer()
                    Button("Cancel") { store.cancel(model) }.font(.caption)
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Retry download") { store.download(model) }
            case nil:
                if store.isInstalled(model) {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } else {
                    Button("Download") { store.download(model) }
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                app.releaseModel()
                store.delete(model)
            }
        } message: {
            Text(String(format: "Frees %.1f GB. You can download it again later.", Double(model.sizeBytes) / 1e9))
        }
    }
}
