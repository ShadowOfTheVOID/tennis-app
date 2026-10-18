import AVFoundation
import ServeAnalysis
import SwiftUI

/// Shot placement from bounces, once the court has been marked on the video.
struct PlacementSection: View {
    let match: AnalyzedMatch
    @State private var taps: [CGPoint]?
    @State private var marking = false

    var body: some View {
        Section {
            if let placement {
                if placement.yours.isEmpty {
                    Text("No bounces were seen on your opponent's side. Bounces are found from the tracked ball, so a clear view of the far court and good light help.")
                } else {
                    PlacementSummary(placement: placement)
                }
            } else {
                Text("Mark the four corners of the singles court on the video to see where your shots land, whether they're in, and how deep they go.")
            }
            Button(taps == nil ? "Mark the court" : "Mark the court again") { marking = true }
        } header: {
            Text("Shot placement (approximate)")
        }
        .sheet(isPresented: $marking) {
            CourtSetupView(video: match.video, time: match.report.strokes.first?.time ?? 0) { taps = $0; marking = false }
        }
    }

    private var placement: Placement? {
        guard let taps, let court = Court.calibrate(taps.map { (Double($0.x), Double($0.y)) }) else { return nil }
        let feet = match.samples.values.compactMap {
            CourtAnalysis.feet($0.pose, width: $0.imageSize.width, height: $0.imageSize.height)
        }
        return CourtAnalysis.placement(match.balls, court: court, playerSpots: feet)
    }
}

private struct PlacementSummary: View {
    let placement: Placement

    var body: some View {
        let p = placement
        VStack(alignment: .leading, spacing: 8) {
            Text("\(p.yours.filter(\.isIn).count) of \(p.yours.count) landed in (\(Int(((p.inRate ?? 0) * 100).rounded()))%) · \(p.long) long · \(p.wide) wide")
                .fontWeight(.semibold)
            Text(Depth.allCases.map { "\($0.title) \(Int(((p.depthRate($0) ?? 0) * 100).rounded()))%" }.joined(separator: "  ·  "))
                .font(.subheadline)
            CourtDiagram(placement: p).aspectRatio(0.75, contentMode: .fit)
            Text("● in   ○ out. Short: inside the service line. Deep: the last 3 m.").font(.caption).foregroundStyle(.secondary)
            if let tip = p.tip { Text(tip).fontWeight(.medium) }
        }
    }
}

/// Your opponent's half of the court, with where your shots bounced.
private struct CourtDiagram: View {
    let placement: Placement
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let mark = scheme == .dark ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
                                   : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
        // Your shots land on the far half; show that half with the net at the bottom.
        let farHalf = placement.yours.first?.half ?? 1
        Canvas { context, size in
            let margin = 2.5 // metres shown beyond the lines, so outs are visible
            let spanX = Court.width + 2 * margin
            let spanY = Court.net + margin + 1
            let scale = min(size.width / spanX, size.height / spanY)
            let ox = (size.width - spanX * scale) / 2
            func at(_ x: Double, _ y: Double) -> CGPoint {
                let fromNet = farHalf == 1 ? y - Court.net : Court.net - y // 0 at the net, up the screen
                return CGPoint(x: ox + (x + margin) * scale, y: size.height - (fromNet + 1) * scale)
            }
            let baseline: Double = farHalf == 1 ? Court.length : 0
            let service = farHalf == 1 ? Court.net + Court.service : Court.net - Court.service
            var lines = Path()
            let segments: [((Double, Double), (Double, Double))] = [
                ((0, Court.net), (Court.width, Court.net)), ((0, baseline), (Court.width, baseline)),
                ((0, Court.net), (0, baseline)), ((Court.width, Court.net), (Court.width, baseline)),
                ((0, service), (Court.width, service)), ((Court.width / 2, Court.net), (Court.width / 2, service)),
            ]
            for (a, b) in segments {
                lines.move(to: at(a.0, a.1))
                lines.addLine(to: at(b.0, b.1))
            }
            context.stroke(lines, with: .color(.secondary), lineWidth: 2)
            for b in placement.yours {
                let c = at(b.x, b.y)
                if b.isIn {
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Color(.secondarySystemGroupedBackground)))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(mark))
                } else {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(mark), lineWidth: 2)
                }
            }
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Court map of where your shots bounced")
    }
}

/// Tap the four corners of the singles court on a frame of the video.
struct CourtSetupView: View {
    let video: URL
    let time: Double
    /// The taps as fractions of the frame.
    let onDone: ([CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var frame: UIImage?
    @State private var taps: [CGPoint] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(prompt).frame(maxWidth: .infinity, alignment: .leading)
                if let frame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                let points = taps.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
                                Path { path in
                                    guard let first = points.first else { return }
                                    path.move(to: first)
                                    points.dropFirst().forEach { path.addLine(to: $0) }
                                    if points.count == 4 { path.closeSubpath() }
                                }
                                .stroke(.yellow, lineWidth: 2)
                                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                                    Circle().fill(.yellow).frame(width: 12, height: 12).position(p)
                                }
                                Color.clear.contentShape(Rectangle())
                                    .onTapGesture { location in
                                        guard taps.count < 4 else { return }
                                        taps.append(CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height))
                                        error = nil
                                    }
                            }
                        }
                } else {
                    ProgressView("Loading a frame…").frame(maxHeight: .infinity)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle("Mark the court")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .bottomBar) { Button("Undo") { _ = taps.popLast() }.disabled(taps.isEmpty) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if Court.calibrate(taps.map { (Double($0.x), Double($0.y)) }) == nil {
                            error = "Those corners don't make a court shape. Tap them in order around the court."
                        } else {
                            onDone(taps)
                        }
                    }
                    .disabled(taps.count < 4)
                }
            }
            .task { await loadFrame() }
        }
    }

    private var prompt: String {
        switch taps.count {
        case 0: "Tap one end of a baseline of the singles court."
        case 1: "Now the other end of the same baseline."
        case 2: "Now the far corner on that side of the court."
        case 3: "And the last corner."
        default: "Done? Check the outline matches the singles lines."
        }
    }

    private func loadFrame() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
            frame = UIImage(cgImage: image)
        }
    }
}
