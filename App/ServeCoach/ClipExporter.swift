import AVFoundation
import ServeAnalysis
import UIKit

/// Renders a stroke's replay into a shareable MP4 with the skeleton and scores drawn on.
enum ClipExporter {
    private static let size = CGSize(width: 720, height: 960)

    enum ExportError: LocalizedError {
        case nothingToExport, writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .nothingToExport: "There are no frames to export."
            case .writerFailed(let message): message
            }
        }
    }

    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    /// Encode the clip into the temporary directory. Takes a few seconds: run it off the main actor.
    static func export(_ stroke: ReviewedStroke) async throws -> URL {
        var source = stroke.replay
        if source.isEmpty {
            source = stroke.result.keyFrames.compactMap { key in
                stroke.images[key.phase].map { ReplayFrame(time: key.frame.time, image: $0, sample: stroke.samples[key.phase]) }
            }
        }
        guard !source.isEmpty else { throw ExportError.nothingToExport }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.removeItem(at: dir) // keep only the latest clip
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(stroke.result.type.rawValue)-\(Int(Date().timeIntervalSince1970)).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)

        let order = ShareClip.frames(source.map(\.time))
        for (n, index) in order.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed("No pixel buffer pool.") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ExportError.writerFailed("Couldn't allocate a frame.") }
            draw(source[index], stroke: stroke, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(ShareClip.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Couldn't finish the video.")
        }
        return url
    }

    private static func draw(_ frame: ReplayFrame, stroke: ReviewedStroke, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // UIKit drawing is y-down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        UIColor.black.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        let image = frame.image
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let rect = CGRect(x: (size.width - image.size.width * scale) / 2, y: (size.height - image.size.height * scale) / 2,
                          width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: rect)

        if let sample = frame.sample, sample.imageSize.width > 0, sample.imageSize.height > 0 {
            // The pose is in the coordinates of the image it was detected on, which may differ in size.
            func at(_ joint: Joint) -> CGPoint? {
                sample.pose[joint].map { CGPoint(x: rect.minX + $0.x * rect.width / sample.imageSize.width,
                                                 y: rect.minY + $0.y * rect.height / sample.imageSize.height) }
            }
            let path = UIBezierPath()
            for (a, b) in bones {
                guard let pa = at(a), let pb = at(b) else { continue }
                path.move(to: pa)
                path.addLine(to: pb)
            }
            path.lineWidth = 6
            path.lineCapStyle = .round
            UIColor.green.setStroke()
            path.stroke()
            UIColor.white.setFill()
            for joint in Joint.allCases {
                if let p = at(joint) { UIBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill() }
            }
        }

        if let ball = stroke.ball(at: frame.time) {
            let c = CGPoint(x: rect.minX + ball.x * rect.width, y: rect.minY + ball.y * rect.height)
            let ring = UIBezierPath(ovalIn: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32))
            ring.lineWidth = 5
            UIColor(red: 1, green: 0.92, blue: 0.23, alpha: 1).setStroke()
            ring.stroke()
        }

        let result = stroke.result
        let band = UIColor.black.withAlphaComponent(0.6)
        band.setFill()
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 130))
        context.fill(CGRect(x: 0, y: size.height - 110, width: size.width, height: 110))
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.white]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white]
        let faint: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white.withAlphaComponent(0.67)]
        let options: NSStringDrawingOptions = [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        (ShareClip.title(result) as NSString).draw(with: CGRect(x: 28, y: 14, width: size.width - 56, height: 50), options: options, attributes: title, context: nil)
        if let caption = ShareClip.caption(result, time: frame.time) {
            (caption as NSString).draw(with: CGRect(x: 28, y: 74, width: size.width - 56, height: 40), options: options, attributes: body, context: nil)
        }
        (ShareClip.footer(result) as NSString).draw(with: CGRect(x: 28, y: size.height - 96, width: size.width - 56, height: 36), options: options, attributes: body, context: nil)
        ("Serve Coach · ¼ speed" as NSString).draw(with: CGRect(x: 28, y: size.height - 56, width: size.width - 56, height: 36), options: options, attributes: faint, context: nil)
    }
}
