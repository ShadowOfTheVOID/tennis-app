import Foundation
import Observation
import ServeAnalysis

/// Downloads, stores and deletes the optional on-device AI coach models.
@MainActor
@Observable
final class ModelStore: NSObject {
    enum DownloadState: Equatable {
        case running(progress: Double)
        case failed(String)
    }

    private(set) var downloads: [String: DownloadState] = [:]
    /// Bumped when a model is installed or deleted so views re-read install state.
    private(set) var version = 0

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var session: URLSession!

    private let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Models are large and can be downloaded again, so keep them out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func url(for model: CoachModel) -> URL { directory.appendingPathComponent(model.fileName) }

    func isInstalled(_ model: CoachModel) -> Bool {
        _ = version
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: model).path)
        return (attributes?[.size] as? Int64) == model.sizeBytes
    }

    var installedModel: CoachModel? { CoachModel.all.first(where: isInstalled) }

    var deviceRAM: UInt64 { ProcessInfo.processInfo.physicalMemory }

    var freeBytes: Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    var recommended: CoachModel? { CoachModel.recommended(forRAM: deviceRAM) }

    func download(_ model: CoachModel) {
        guard tasks[model.id] == nil else { return }
        guard freeBytes > model.sizeBytes + 200_000_000 else {
            downloads[model.id] = .failed("Not enough storage: \(model.name) needs \(model.sizeBytes / 1_000_000_000) GB free.")
            return
        }
        let task = resumeData.removeValue(forKey: model.id).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        downloads[model.id] = .running(progress: 0)
        task.resume()
    }

    func cancel(_ model: CoachModel) {
        tasks.removeValue(forKey: model.id)?.cancel(byProducingResumeData: { _ in })
        downloads[model.id] = nil
    }

    func delete(_ model: CoachModel) {
        try? FileManager.default.removeItem(at: url(for: model))
        version += 1
    }

    fileprivate func finished(_ id: String, file: URL?, error: Error?) {
        tasks[id] = nil
        guard let model = CoachModel.all.first(where: { $0.id == id }) else { return }
        if let error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData[id] = data
            }
            // A cancel clears the state itself; anything else is shown with a retry button.
            if (error as NSError).code != NSURLErrorCancelled {
                downloads[id] = .failed("Download stopped: \(error.localizedDescription) Tap retry to resume.")
            }
            return
        }
        guard let file else { return }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
            guard size == model.sizeBytes else { throw CocoaError(.fileReadCorruptFile) }
            try? FileManager.default.removeItem(at: url(for: model))
            try FileManager.default.moveItem(at: file, to: url(for: model))
            downloads[id] = nil
            version += 1
        } catch {
            downloads[id] = .failed("The download was incomplete. Please try again.")
        }
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it somewhere safe first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let id = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated { finished(id, file: moved ? kept : nil, error: nil) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskDescription ?? ""
        MainActor.assumeIsolated { finished(id, file: nil, error: error) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated {
            guard let model = CoachModel.all.first(where: { $0.id == id }) else { return }
            downloads[id] = .running(progress: Double(totalBytesWritten) / Double(model.sizeBytes))
        }
    }
}
