import AVFoundation
import ServeAnalysis
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let position: AVCaptureDevice.Position

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // Re-apply after camera switches, which recreate the connection.
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

struct LiveCoachView: View {
    @AppStorage("handedness") private var hand: Handedness = .right
    @AppStorage("spokenCues") private var spokenCues = true
    /// A `StrokeType` raw value, or "any" to work it out from each swing.
    @AppStorage("practiceStroke") private var practiceStroke = StrokeType.serve.rawValue
    @Environment(AppState.self) private var app
    @State private var camera = CameraModel()
    @State private var showLiveChecks = false
    @State private var reviewing: ReviewedStroke?

    private var stroke: StrokeType? { StrokeType(rawValue: practiceStroke) }

    var body: some View {
        ZStack {
            if camera.permissionDenied {
                ContentUnavailableView(
                    "Camera access needed",
                    systemImage: "camera.fill",
                    description: Text("Allow camera access in Settings to get live posture feedback.")
                )
            } else {
                CameraPreview(session: camera.session, position: camera.position)
                    .ignoresSafeArea()
                SkeletonOverlay(sample: camera.sample, fill: true, mirrored: camera.position == .front, color: phaseColor)
                    .ignoresSafeArea()
                VStack {
                    header
                    Spacer()
                    feedback
                }
                .padding()
            }
        }
        .onAppear { camera.start(hand: hand, stroke: stroke) }
        .onDisappear { camera.stop() }
        .onChange(of: hand) { _, newHand in camera.setTracking(hand: newHand, stroke: stroke) }
        .onChange(of: practiceStroke) { camera.setTracking(hand: hand, stroke: stroke) }
        .onChange(of: spokenCues, initial: true) { _, on in camera.spokenCues = on }
        .onChange(of: camera.strokeCount) {
            if let stroke = camera.lastStroke { app.record(stroke, hand: hand) }
        }
        .sheet(item: $reviewing) { stroke in
            NavigationStack {
                StrokeReviewView(stroke: stroke, hand: hand)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { reviewing = nil } }
            }
        }
    }

    private var phaseColor: Color {
        guard stroke == .serve else { return .green }
        switch camera.sample.map({ ServeAnalyzer.phase(of: $0.pose, hand: hand) }) {
        case .trophy: .yellow
        case .contact: .cyan
        default: .green
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
            Picker("Hand", selection: $hand) {
                Text("Righty").tag(Handedness.right)
                Text("Lefty").tag(Handedness.left)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            Toggle(isOn: $spokenCues) { Image(systemName: "speaker.wave.2.fill") }
                .toggleStyle(.button)

            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
            }
            .buttonStyle(.bordered)
            }
            StrokePicker(selection: $practiceStroke)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var feedback: some View {
        Picker("Mode", selection: $showLiveChecks) {
            Text("Last stroke").tag(false)
            Text(stroke == .serve ? "Hold pose" : "Ready position").tag(true)
        }
        .pickerStyle(.segmented)

        ScrollView {
            if showLiveChecks {
                if let live = camera.liveEvaluation {
                    EvaluationCard(evaluation: live)
                } else {
                    hint(stroke == .serve ? "Raise your tossing arm into the trophy position and hold it."
                         : "Get into your ready position: knees bent, feet wide, racket up in front.")
                }
            } else if let last = camera.lastStroke {
                VStack(spacing: 12) {
                    HStack {
                        Text("\(last.result.title) #\(camera.strokeCount)").font(.headline)
                        Spacer()
                        Button {
                            reviewing = last
                        } label: {
                            Label("AI coach", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        ScoreBadge(score: last.result.score)
                    }
                    .padding(.horizontal)
                    ForEach(last.result.evaluations, id: \.phase) { EvaluationCard(evaluation: $0) }
                }
            } else {
                hint("Set the phone up side-on, about 4 m away, with your whole body in frame. Then hit!")
            }
        }
        .frame(maxHeight: 340)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Serve, Forehand, ... or Any (worked out from each swing). Bound to a `StrokeType` raw value or "any".
struct StrokePicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Any", value: "any")
                ForEach(StrokeType.allCases, id: \.self) { chip($0.title, value: $0.rawValue) }
            }
        }
    }

    private func chip(_ title: String, value: String) -> some View {
        Button(title) { selection = value }
            .buttonStyle(.bordered)
            .tint(selection == value ? .accentColor : .secondary)
            .font(.subheadline.weight(selection == value ? .semibold : .regular))
    }
}
