import Foundation
import Observation

/// Downloads one file from the laptop into a temp folder so Quick Look can open it.
@MainActor
@Observable
final class Downloader {
    enum Phase: Equatable {
        case downloading
        case done(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .downloading
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0

    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Open", isDirectory: true) }

    static func clearOldFiles() {
        try? FileManager.default.removeItem(at: folder)
    }

    var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }

    var progressText: String {
        if expected > 0 {
            return "Downloading, \(Int(fraction * 100)) percent, \(Format.size(received)) of \(Format.size(expected))"
        }
        return received > 0 ? "Downloading, \(Format.size(received))" : "Downloading"
    }

    func start(path: String, name: String, size: Int64, client: ConnectClient) {
        guard task == nil else { return }
        expected = max(size, 0)
        guard let url = client.fileURL(path) else {
            fail(ConnectError.badComputerName.errorDescription ?? "")
            return
        }
        let dir = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        let host = client.host
        let task = ConnectClient.session.downloadTask(with: client.request(url, timeout: 60)) { [weak self] temp, response, error in
            let outcome: Phase
            if let error {
                if (error as? URLError)?.code == .cancelled { return }
                let e = (error as? URLError).map { ConnectError.from(urlError: $0, host: host) } ?? ConnectError.notAnswering(host)
                outcome = .failed(e.errorDescription ?? "")
            } else if let http = response as? HTTPURLResponse, let failure = ConnectError.from(status: http.statusCode) {
                outcome = .failed(failure.errorDescription ?? "")
            } else if let temp {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temp, to: dest)
                    outcome = .done(dest)
                } catch {
                    outcome = .failed("Couldn't save the file. \(error.localizedDescription)")
                }
            } else {
                outcome = .failed(ConnectError.badResponse.errorDescription ?? "")
            }
            Task { @MainActor in self?.finish(outcome) }
        }
        progressObservation = task.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] p, _ in
            let done = p.completedUnitCount
            let total = p.totalUnitCount
            Task { @MainActor in self?.update(done, total) }
        }
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        progressObservation = nil
    }

    private func update(_ done: Int64, _ total: Int64) {
        guard phase == .downloading else { return }
        received = done
        if total > 0 { expected = total }
    }

    private func finish(_ outcome: Phase) {
        progressObservation = nil
        phase = outcome
        if case .failed(let message) = outcome { Announce.say(message) }
    }

    private func fail(_ message: String) {
        finish(.failed(message))
    }
}
