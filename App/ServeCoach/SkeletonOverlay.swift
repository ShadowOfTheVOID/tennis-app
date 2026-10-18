import ServeAnalysis
import SwiftUI

/// Draws a pose skeleton over an image or camera preview of `imageSize`,
/// laid out with the same aspect-fill or aspect-fit as the content beneath it.
struct SkeletonOverlay: View {
    let sample: PoseSample?
    var fill = true
    var mirrored = false
    var color: Color = .green
    /// A ball to ring, as fractions of the image.
    var ball: BallSighting?

    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        Canvas { context, size in
            guard let sample, sample.imageSize.width > 0, sample.imageSize.height > 0 else { return }
            let img = sample.imageSize
            let scale = fill
                ? max(size.width / img.width, size.height / img.height)
                : min(size.width / img.width, size.height / img.height)
            let offset = CGPoint(x: (size.width - img.width * scale) / 2, y: (size.height - img.height * scale) / 2)

            func map(_ p: Point) -> CGPoint {
                let x = mirrored ? img.width - p.x : p.x
                return CGPoint(x: x * scale + offset.x, y: p.y * scale + offset.y)
            }

            var path = Path()
            for (a, b) in Self.bones {
                guard let pa = sample.pose[a], let pb = sample.pose[b] else { continue }
                path.move(to: map(pa))
                path.addLine(to: map(pb))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))

            for joint in Joint.allCases {
                guard let p = sample.pose[joint] else { continue }
                let c = map(p)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.white))
            }
            if let ball {
                let c = map(Point(x: ball.x * img.width, y: ball.y * img.height))
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)),
                               with: .color(Color(red: 1, green: 0.92, blue: 0.23)), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }
}
