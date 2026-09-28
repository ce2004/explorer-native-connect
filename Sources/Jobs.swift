import Foundation
import Observation

/// Copies, moves and uploads that are running, with progress.
@MainActor
@Observable
final class JobCenter {
    struct Job: Identifiable, Equatable {
        let id: String
        var status: JobStatus
        var waiting = false
        var finished: Bool { !status.isRunning }

        /// "Copying, 3 of 10 items, 1.2 GB of 4 GB, now song.flac"
        var spoken: String {
            if finished { return status.finishedText }
            var text = status.progressText
            if waiting { text += ", waiting for the laptop" }
            if !status.current.isEmpty { text += ", now \(status.current)" }
            return text
        }
    }

    private(set) var jobs: [Job] = []

    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var onConnectionProblem: (@MainActor (Error) -> Void)?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var clients: [String: ConnectClient] = [:]

    /// Starts a copy or move on the laptop and follows it.
    func startCopy(_ paths: [String], to destination: String, move: Bool, conflict: Conflict, client: ConnectClient) async {
        do {
            let id = try await client.copy(paths, to: destination, conflict: conflict, move: move)
            let status = JobStatus(id: id, kind: move ? "move" : "copy", state: "running", items: paths.count)
            jobs.append(Job(id: id, status: status))
            clients[id] = client
            Announce.say(move ? "Moving." : "Copying.")
            tasks[id] = Task { [weak self] in await self?.follow(id, client: client) }
        } catch {
            onConnectionProblem?(error)
            Announce.say(ConnectError.message(for: error))
        }
    }

    private func follow(_ id: String, client: ConnectClient) async {
        var delay: Double = 0.7
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            do {
                let status = try await client.job(id)
                delay = 0.7
                update(id) { $0.status = status; $0.waiting = false }
                if !status.isRunning {
                    finish(id)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep following through a dropped connection; the job keeps running on the laptop.
                if ConnectError.isConnectionProblem(error) {
                    update(id) { $0.waiting = true }
                    onConnectionProblem?(error)
                    delay = min(delay * 2, 15)
                } else {
                    update(id) {
                        $0.status.state = "failed"
                        $0.status.message = ConnectError.message(for: error)
                    }
                    finish(id)
                    return
                }
            }
        }
    }

    func cancel(_ id: String) {
        if id.hasPrefix("upload-") {
            tasks[id]?.cancel()
            update(id) { $0.status.state = "cancelled" }
            finish(id)
            return
        }
        guard let client = clients[id] else { return }
        Task {
            do {
                try await client.cancelJob(id)
            } catch {
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    func dismiss(_ id: String) {
        jobs.removeAll { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func finish(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        tasks[id] = nil
        clients[id] = nil
        Announce.say(job.status.finishedText)
        onChange?()
        // A clean finish goes away; one with problems stays so its message can be read again.
        if job.status.state == "done" && job.status.failed.isEmpty {
            jobs.removeAll { $0.id == id }
        }
    }
}

/// Folder sizes, fetched lazily and never more than two at a time.
@MainActor
@Observable
final class FolderSizes {
    private(set) var results: [String: FolderSize] = [:]

    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var client: ConnectClient?
    static let maxConcurrent = 2

    func result(for path: String) -> FolderSize? { results[path.lowercased()] }

    /// A folder row came into view.
    func want(_ path: String, client: ConnectClient) {
        self.client = client
        let key = path.lowercased()
        guard results[key] == nil, !running.contains(key), !queue.contains(where: { $0.lowercased() == key }) else { return }
        queue.append(path)
        pump()
    }

    /// The row scrolled away before its turn.
    func unwant(_ path: String) {
        let key = path.lowercased()
        queue.removeAll { $0.lowercased() == key }
    }

    /// "Get size": straight away, not queued.
    func fetch(_ path: String, client: ConnectClient) async throws -> FolderSize {
        let size = try await client.size(path)
        results[path.lowercased()] = size
        return size
    }

    func forget(inside folder: String) {
        for key in results.keys where RemotePath.isInside(key, folder) || RemotePath.isInside(folder, key) {
            results[key] = nil
        }
    }

    func clear() {
        results = [:]
        queue = []
    }

    var inFlight: Int { running.count }

    private func pump() {
        while running.count < Self.maxConcurrent, !queue.isEmpty, let client {
            let path = queue.removeFirst()
            let key = path.lowercased()
            running.insert(key)
            Task { [weak self] in
                let size = try? await client.size(path)
                guard let self else { return }
                self.running.remove(key)
                if let size { self.results[key] = size }
                self.pump()
            }
        }
    }
}
