import CoreGraphics
import CoreVideo
import ServeAnalysis
import Vision

/// A detected pose together with the size of the image it was found in.
struct PoseSample {
    let pose: Pose
    let imageSize: CGSize
}

/// Wraps Apple Vision's on-device body pose detector and converts its output into
/// `ServeAnalysis.Pose` (pixel coordinates, y down). Not thread-safe: use one per queue.
final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()

    private static let mapping: [Joint: VNHumanBodyPoseObservation.JointName] = [
        .nose: .nose,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    func detect(pixelBuffer: CVPixelBuffer) -> PoseSample? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up), size: size)
    }

    func detect(cgImage: CGImage) -> PoseSample? {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return perform(VNImageRequestHandler(cgImage: cgImage, orientation: .up), size: size)
    }

    private func perform(_ handler: VNImageRequestHandler, size: CGSize) -> PoseSample? {
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // When several people are in frame (e.g. an opponent across the net), use the largest.
        let poses = (request.results ?? []).compactMap { pose(from: $0, size: size) }
        guard let best = poses.max(by: { ($0.torsoLength ?? 0) < ($1.torsoLength ?? 0) }) else { return nil }
        return PoseSample(pose: best, imageSize: size)
    }

    private func pose(from observation: VNHumanBodyPoseObservation, size: CGSize) -> Pose? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [Joint: Point] = [:]
        for (joint, name) in Self.mapping {
            guard let p = points[name] else { continue }
            // Vision uses normalised coordinates with the origin at the bottom-left.
            joints[joint] = Point(
                x: Double(p.location.x) * size.width,
                y: (1 - Double(p.location.y)) * size.height,
                confidence: Double(p.confidence)
            )
        }
        return Pose(joints: joints)
    }
}
