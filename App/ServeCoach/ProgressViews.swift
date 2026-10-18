import ServeAnalysis
import SwiftUI
import UserNotifications

/// Per-check progress for one stroke, serve rhythm and top hand speeds.
struct ProgressTabView: View {
    @Environment(AppState.self) private var app
    @State private var kind: StrokeType?

    var body: some View {
        let kinds = StrokeType.allCases.filter { t in app.history.contains { $0.kind == t.rawValue } }
        if let selected = kind ?? kinds.first {
            let progress = PracticeStats.progress(app.history, kind: selected.rawValue)
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(kinds, id: \.self) { t in
                                Button(t.title) { kind = t }
                                    .buttonStyle(.bordered)
                                    .tint(selected == t ? .accentColor : .secondary)
                            }
                        }
                    }
                    if let top = PracticeStats.topSpeeds(app.history)[selected.rawValue] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fastest \(selected.title.lowercased())").font(.caption.weight(.semibold))
                            Text(String(format: "≈ %.1f m/s hand speed (%d km/h)", top, Int((top * 3.6).rounded()))).font(.headline)
                            Text("Estimated from your hand, not the racket head, which moves faster.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if selected == .serve, let rhythm = PracticeStats.rhythm(app.history) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Serve rhythm").font(.caption.weight(.semibold))
                            Text(rhythm.verdict).font(.headline)
                            Text(String(format: "%.2f s from trophy to contact on average, ± %.2f s over %d serves",
                                        rhythm.average, rhythm.spread, rhythm.count))
                                .font(.subheadline)
                            Text(rhythm.tip).font(.caption)
                        }
                    }
                }
                Section("Each check: share graded good per week") {
                    ForEach(progress) { ProgressTile(progress: $0) }
                }
            }
        } else {
            ContentUnavailableView("No progress yet", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Record a few strokes to see your progress here."))
        }
    }
}

/// One check: latest rate, change, and a weekly sparkline (single series, so no legend).
private struct ProgressTile: View {
    let progress: CheckProgress

    var body: some View {
        let latest = progress.weeks.last?.goodRate ?? 0
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.label).font(.subheadline.weight(.semibold))
                Text(progress.summary).font(.caption)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int((latest * 100).rounded()))%").font(.headline)
                // Direction is shown with an arrow, not colour alone.
                if let change = progress.change {
                    Text(change > 0 ? "▲ +\(change) pts" : change < 0 ? "▼ \(change) pts" : "– no change").font(.caption2)
                }
            }
            Sparkline(weeks: progress.weeks).frame(width: 96, height: 36)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Sparkline: View {
    let weeks: [WeekRate]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let line = scheme == .dark ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
                                   : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
        Canvas { context, size in
            // x: weeks (oldest left), y: 0–100 % good. Recessive baseline only.
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height))
            base.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(base, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            guard !weeks.isEmpty else { return }
            let oldest = Double(max(weeks[0].weeksAgo, 1))
            let points = weeks.map { w in
                CGPoint(x: weeks.count == 1 ? size.width : size.width * (1 - Double(w.weeksAgo) / oldest),
                        y: size.height * (1 - w.goodRate))
            }
            if points.count > 1 {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            // End marker with a surface ring, so it reads over the line.
            let end = points[points.count - 1]
            context.fill(Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)), with: .color(Color(.systemBackground)))
            context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)), with: .color(line))
        }
        .accessibilityHidden(true)
    }
}

/// This week's practice plan, and the daily reminder.
struct PlanView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Reminders.onKey) private var reminder = false
    @AppStorage(Reminders.hourKey) private var hour = 18
    @State private var denied = false

    var body: some View {
        let plan = PracticePlan.make(app.history)
        let today = reminder ? Reminders.planDay() : nil
        List {
            Section("Your focus this week") {
                if plan.focus.isEmpty {
                    Text("Record some strokes and your plan will build itself from what needs the most work.")
                }
                ForEach(plan.focus) { f in
                    Text("\(f.strokeTitle): \(f.label) — needed work \(Int((f.missRate * 100).rounded()))% of the time")
                }
            }
            Section {
                Toggle("Daily reminder", isOn: Binding(get: { reminder }, set: { on in
                    if on {
                        Task {
                            if await Reminders.enable(hour: hour, plan: plan) { reminder = true } else { denied = true }
                        }
                    } else {
                        Reminders.disable()
                        reminder = false
                    }
                }))
                Picker("Time", selection: $hour) {
                    ForEach([7, 12, 18, 20], id: \.self) { Text("\($0):00").tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: hour) { _, h in
                    if reminder { Task { _ = await Reminders.enable(hour: h, plan: plan) } }
                }
            } footer: {
                Text(denied ? "Notifications are off for Serve Coach. Turn them on in the Settings app to get reminders."
                     : "You'll get today's part of the plan at that time. Turning it on starts the week today.")
            }
            ForEach(plan.days) { day in
                Section {
                    ForEach(day.items, id: \.self) { Text("• \($0)").font(.subheadline) }
                } header: {
                    Text("Day \(day.day)\(day.day == today ? " · today" : ""): \(day.title)")
                }
            }
        }
        .task(id: app.history.count) {
            // Keep the scheduled reminders in step with the latest plan.
            if reminder { await Reminders.reschedule(hour: hour, plan: plan) }
        }
    }
}

/// Daily practice reminders that say which day of the plan it is. Scheduled a week ahead.
enum Reminders {
    static let onKey = "reminderOn"
    static let hourKey = "reminderHour"
    private static let startKey = "planStart"
    private static let prefix = "practice-"

    /// Day of the plan (1–7), counting from when reminders were turned on.
    static func planDay(now: Date = Date()) -> Int {
        let start = UserDefaults.standard.object(forKey: startKey) as? Date ?? now
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        return ((days % 7) + 7) % 7 + 1
    }

    /// Ask for permission, start the plan's week today, and schedule. False if notifications are refused.
    static func enable(hour: Int, plan: PracticePlan) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        if !UserDefaults.standard.bool(forKey: onKey) { UserDefaults.standard.set(Date(), forKey: startKey) }
        await reschedule(hour: hour, plan: plan)
        return true
    }

    static func disable() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<7).map { prefix + String($0) })
    }

    /// One notification for each of the next 7 days, each naming that day's part of the plan.
    static func reschedule(hour: Int, plan: PracticePlan) async {
        disable()
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let now = Date()
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), fire > now,
                  let entry = plan.days.first(where: { $0.day == planDay(now: fire) })
            else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Today: \(entry.title)"
            content.body = entry.items.joined(separator: "\n")
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + String(offset), content: content, trigger: trigger))
        }
    }
}
