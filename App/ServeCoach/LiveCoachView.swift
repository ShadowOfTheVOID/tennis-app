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
    @State private var camera = CameraModel()
    @State private var showLiveChecks = false
    @State private var reviewing: ReviewedServe?

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
        .onAppear { camera.start(hand: hand) }
        .onDisappear { camera.stop() }
        .onChange(of: hand) { _, newHand in camera.setHand(newHand) }
        .sheet(item: $reviewing) { serve in
            NavigationStack {
                ServeReviewView(serve: serve, hand: hand)
                    .navigationTitle("Serve review")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { reviewing = nil } }
            }
        }
    }

    private var phaseColor: Color {
        switch camera.sample.map({ ServeAnalyzer.phase(of: $0.pose, hand: hand) }) {
        case .trophy: .yellow
        case .contact: .cyan
        default: .green
        }
    }

    private var header: some View {
        HStack {
            Picker("Hand", selection: $hand) {
                Text("Righty").tag(Handedness.right)
                Text("Lefty").tag(Handedness.left)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            Toggle(isOn: $camera.spokenCues) { Image(systemName: "speaker.wave.2.fill") }
                .toggleStyle(.button)

            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var feedback: some View {
        Picker("Mode", selection: $showLiveChecks) {
            Text("Last serve").tag(false)
            Text("Hold pose").tag(true)
        }
        .pickerStyle(.segmented)

        ScrollView {
            if showLiveChecks {
                if let live = camera.liveEvaluation {
                    EvaluationCard(evaluation: live)
                } else {
                    hint("Raise your tossing arm into the trophy position and hold it.")
                }
            } else if let serve = camera.lastServe {
                VStack(spacing: 12) {
                    HStack {
                        Text("Serve #\(camera.serveCount)").font(.headline)
                        Spacer()
                        Button {
                            reviewing = serve
                        } label: {
                            Label("AI coach", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        ScoreBadge(score: serve.result.score)
                    }
                    .padding(.horizontal)
                    if let trophy = serve.result.trophy { EvaluationCard(evaluation: trophy) }
                    if let contact = serve.result.contact { EvaluationCard(evaluation: contact) }
                }
            } else {
                hint("Set the phone up side-on, about 4 m away, with your whole body in frame. Then serve!")
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
