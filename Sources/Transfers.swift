import Foundation
import Observation
import UIKit

/// One file going to or from the laptop. Saved to disk so transfers survive the app being closed.
struct TransferRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case upload, download }
    enum State: String, Codable { case running, paused, waiting, finishing, sendingToDrive, done, failed, cancelled }

    var id: String = UUID().uuidString
    var direction: Direction
    var name: String
    var size: Int64
    var done: Int64 = 0
    var state: State = .running
    var message: String = ""
    var created = Date()

    // Phone to PC
    var folder: String = ""
    var conflict: String = Conflict.rename.rawValue
    var sourceBookmark: Data?
    /// A copy kept in the app's own storage (from Photos), relative to the staging folder.
    var stagedName: String?
    var uploadID: String?
    var jobID: String?
    var resultPath: String?

    // PC to phone
    var remotePath: String = ""
    /// The finished file's name in Documents.
    var savedName: String?

    var isActive: Bool { [.running, .waiting, .finishing, .sendingToDrive].contains(state) }
    var isFinished: Bool { [.done, .failed, .cancelled].contains(state) }
}

enum TransferText {
    /// "tone.flac, sending, 45 percent, 1.2 GB of 2.7 GB, 12 MB per second, 2 minutes left"
    static func describe(_ r: TransferRecord, rate: Double) -> String {
        var parts = [r.name]
        switch r.state {
        case .done:
            parts.append(r.direction == .upload ? "sent" : "saved to iPhone")
            return parts.joined(separator: ", ")
        case .failed:
            parts.append("failed")
            if !r.message.isEmpty { parts.append(r.message) }
            return parts.joined(separator: ", ")
        case .cancelled:
            parts.append("cancelled")
            return parts.joined(separator: ", ")
        case .paused: parts.append("paused")
        case .waiting: parts.append("waiting for the laptop")
        case .finishing: parts.append("finishing")
        case .sendingToDrive: parts.append("sending to Google Drive")
        case .running: parts.append(r.direction == .upload ? "sending" : "saving to iPhone")
        }
        if r.size > 0 {
            parts.append("\(TransferMath.percent(r.done, r.size)) percent")
            parts.append("\(Format.size(r.done)) of \(Format.size(r.size))")
        } else if r.done > 0 {
            parts.append(Format.size(r.done))
        }
        if r.state == .running || r.state == .sendingToDrive, rate > 1 {
            parts.append(TransferMath.speed(rate))
            if r.size > 0, let left = RateMeter.secondsLeft(rate: rate, remaining: r.size - r.done) {
                parts.append(TransferMath.timeLeft(left))
            }
        }
        return parts.joined(separator: ", ")
    }
}

extension RateMeter {
    static func secondsLeft(rate: Double, remaining: Int64) -> Double? {
        guard rate > 1, remaining > 0 else { return nil }
        return Double(remaining) / rate
    }
}

/// The background URLSession that saves files to the phone, so downloads carry on with the app in the background.
/// Files come down in ranged chunks appended to a partial file, so a dropout or relaunch loses at most one chunk.
final class DownloadEngine: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadEngine()
    static let identifier = "com.conner.explorerconnect.downloads"

    /// (transfer id, chunk start, bytes of this chunk so far)
    var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    /// (transfer id, chunk start, downloaded chunk file or nil, HTTP status, error)
    var onChunk: (@Sendable (String, Int64, URL?, Int, Error?) -> Void)?
    var backgroundCompletion: (() -> Void)?

    private let lock = NSLock()
    private var finishedFiles: [ObjectIdentifier: URL] = [:]
    private var _useBackground = false

    /// While the app is in front, chunks go through an ordinary session (quick to start, and reliable in the
    /// simulator); once it goes to the background they go through the background session, which iOS keeps running.
    var useBackground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useBackground }
        set { lock.lock(); _useBackground = newValue; lock.unlock() }
    }

    lazy var foreground: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.timeoutIntervalForRequest = 60
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    static var chunkFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers/Chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start(_ request: URLRequest, id: String, chunkStart: Int64) {
        let task = (useBackground ? session : foreground).downloadTask(with: request)
        task.taskDescription = "\(id)|\(chunkStart)"
        task.resume()
    }

    func cancel(_ id: String) {
        for s in [session, foreground] {
            s.getAllTasks { tasks in
                for t in tasks where Self.parse(t.taskDescription)?.0 == id { t.cancel() }
            }
        }
    }

    /// Stops the chunks running in the ordinary session (the app is going to the background); returns their ids so
    /// they can be asked for again through the background session.
    func cancelForeground() async -> Set<String> {
        let tasks = await foreground.allTasks
        for t in tasks { t.cancel() }
        return Set(tasks.compactMap { Self.parse($0.taskDescription)?.0 })
    }

    /// Transfer ids with a chunk still in flight (after a relaunch).
    func activeIDs() async -> Set<String> {
        let a = await session.allTasks
        let b = await foreground.allTasks
        return Set((a + b).compactMap { Self.parse($0.taskDescription)?.0 })
    }

    static func parse(_ description: String?) -> (String, Int64)? {
        guard let d = description, let bar = d.lastIndex(of: "|"), let start = Int64(d[d.index(after: bar)...]) else { return nil }
        return (String(d[..<bar]), start)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parsed = Self.parse(downloadTask.taskDescription) else { return }
        onProgress?(parsed.0, parsed.1, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file vanishes when this returns, so move it now.
        let dest = Self.chunkFolder.appendingPathComponent(UUID().uuidString)
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil {
            lock.lock()
            finishedFiles[ObjectIdentifier(downloadTask)] = dest
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let parsed = Self.parse(task.taskDescription) else { return }
        let (id, start) = parsed
        lock.lock()
        let file = finishedFiles.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        onChunk?(id, start, error == nil ? file : nil, status, error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Every transfer between the phone and the laptop.
@MainActor
@Observable
final class TransferCenter {
    private(set) var records: [TransferRecord] = []
    private(set) var rates: [String: Double] = [:]

    @ObservationIgnored var clientProvider: (@MainActor () -> ConnectClient)?
    @ObservationIgnored var announceProgress = true
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var onConnectionProblem: (@MainActor (Error) -> Void)?
    @ObservationIgnored var uploadChunkSize: Int64 = 8 * 1024 * 1024
    @ObservationIgnored var downloadChunkSize: Int64 = 16 * 1024 * 1024

    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var meters: [String: RateMeter] = [:]
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var lastAnnouncement = Date.distantPast
    @ObservationIgnored private var retryDelay: [String: Double] = [:]
    @ObservationIgnored private let engine = DownloadEngine.shared

    nonisolated static var baseFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var stagingFolder: URL {
        let dir = baseFolder.appendingPathComponent("Outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var partialFolder: URL {
        let dir = baseFolder.appendingPathComponent("Partial", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated private static var storeURL: URL { baseFolder.appendingPathComponent("transfers.json") }

    var active: [TransferRecord] { records.filter { !$0.isFinished } }

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([TransferRecord].self, from: data) {
            records = saved
        }
        engine.onProgress = { [weak self] id, start, got in
            Task { @MainActor in self?.downloadProgress(id, start + got) }
        }
        engine.onChunk = { [weak self] id, start, file, status, error in
            Task { @MainActor in self?.chunkFinished(id, start, file, status, error) }
        }
        // Reconnect to the background session so chunks that finished while we were away get reported.
        _ = engine.session
        engine.useBackground = UIApplication.shared.applicationState == .background
    }

    /// After launch: pick up whatever was running.
    func resumeAfterLaunch() {
        Task {
            let inFlight = await engine.activeIDs()
            for r in records where r.isActive {
                if r.direction == .download {
                    if !inFlight.contains(r.id) { requestNextChunk(r.id) }
                } else {
                    startUploadWorker(r.id)
                }
            }
        }
    }

    /// The app went to the background: move running downloads onto the background session so they carry on.
    func appWentToBackground() {
        engine.useBackground = true
        Task {
            let moved = await engine.cancelForeground()
            for id in moved where record(id)?.state == .running { requestNextChunk(id) }
        }
    }

    func appCameToFront() {
        engine.useBackground = false
    }

    /// The laptop is back: retry anything that was waiting for it.
    func connectionRestored() {
        for r in records where r.state == .waiting {
            retryDelay[r.id] = nil
            resume(r.id)
        }
    }

    // MARK: - Starting

    func upload(files: [URL], to folder: String, conflict: Conflict) {
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var r = TransferRecord(direction: .upload, name: url.lastPathComponent, size: size)
            r.folder = folder
            r.conflict = conflict.rawValue
            r.sourceBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if r.sourceBookmark == nil {
                // No bookmark (some providers): keep our own copy so the transfer can resume.
                let staged = UUID().uuidString + "-" + url.lastPathComponent
                guard (try? FileManager.default.copyItem(at: url, to: Self.stagingFolder.appendingPathComponent(staged))) != nil else {
                    Announce.say("Can't read \(url.lastPathComponent).")
                    continue
                }
                r.stagedName = staged
            }
            add(r)
            startUploadWorker(r.id)
        }
        announceStart(files.count, upload: true)
    }

    /// Files already copied into the staging folder (from Photos).
    func upload(staged: [(name: String, stagedName: String)], to folder: String, conflict: Conflict) {
        for item in staged {
            let url = Self.stagingFolder.appendingPathComponent(item.stagedName)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var r = TransferRecord(direction: .upload, name: item.name, size: size)
            r.folder = folder
            r.conflict = conflict.rawValue
            r.stagedName = item.stagedName
            add(r)
            startUploadWorker(r.id)
        }
        announceStart(staged.count, upload: true)
    }

    func download(_ items: [(path: String, name: String, size: Int64)]) {
        for item in items {
            var r = TransferRecord(direction: .download, name: item.name, size: max(item.size, -1))
            r.remotePath = item.path
            add(r)
            requestNextChunk(r.id)
        }
        announceStart(items.count, upload: false)
    }

    private func announceStart(_ count: Int, upload: Bool) {
        guard count > 0 else { return }
        let what = count == 1 ? "1 file" : "\(count) files"
        Announce.say(upload ? "Sending \(what)." : "Saving \(what) to iPhone.")
    }

    // MARK: - Controls

    func pause(_ id: String) {
        guard let r = record(id), r.isActive else { return }
        update(id) { $0.state = .paused }
        workers[id]?.cancel()
        workers[id] = nil
        if r.direction == .download { engine.cancel(id) }
        meters[id]?.reset()
        rates[id] = nil
    }

    func resume(_ id: String) {
        guard let r = record(id), [.paused, .waiting, .failed].contains(r.state) else { return }
        update(id) {
            $0.state = .running
            $0.message = ""
        }
        if r.direction == .download {
            requestNextChunk(id)
        } else {
            startUploadWorker(id)
        }
    }

    func cancel(_ id: String) {
        guard let r = record(id) else { return }
        workers[id]?.cancel()
        workers[id] = nil
        if r.direction == .download {
            engine.cancel(id)
            try? FileManager.default.removeItem(at: partialURL(id))
        } else {
            if let uploadID = r.uploadID, let client = clientProvider?() {
                Task { try? await client.uploadCancel(uploadID) }
            }
            if let jobID = r.jobID, let client = clientProvider?() {
                Task { try? await client.cancelJob(jobID) }
            }
            removeStaged(r)
        }
        records.removeAll { $0.id == id }
        rates[id] = nil
        save(force: true)
        Announce.say("Cancelled \(r.name).")
    }

    func remove(_ id: String) {
        guard let r = record(id), r.isFinished || r.state == .paused else { return }
        if r.state == .paused { cancel(id); return }
        records.removeAll { $0.id == id }
        save(force: true)
    }

    func clearFinished() {
        records.removeAll { $0.isFinished }
        save(force: true)
    }

    func savedURL(_ r: TransferRecord) -> URL? {
        guard let name = r.savedName else { return nil }
        let url = Self.documents.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func rate(_ id: String) -> Double { rates[id] ?? 0 }

    // MARK: - Records

    func record(_ id: String) -> TransferRecord? { records.first { $0.id == id } }

    private func add(_ r: TransferRecord) {
        records.append(r)
        save(force: true)
    }

    private func update(_ id: String, _ change: (inout TransferRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
        let r = records[i]
        save(force: !r.isActive || r.state != .running)
    }

    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 2 else { return }
        lastSaved = Date()
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    /// Progress bookkeeping shared by both directions: speed, and a spoken note every 10 %.
    private func progressed(_ id: String, to done: Int64) {
        guard let r = record(id) else { return }
        let old = r.done
        update(id) { $0.done = done }
        var meter = meters[id] ?? RateMeter()
        meter.add(total: done, at: Date().timeIntervalSince1970)
        meters[id] = meter
        rates[id] = meter.rate
        if announceProgress, let step = TransferMath.crossedStep(from: old, to: done, total: r.size),
           Date().timeIntervalSince(lastAnnouncement) > 4 {
            lastAnnouncement = Date()
            Announce.say("\(r.name), \(step) percent.")
        }
    }

    private func finished(_ id: String, _ text: String) {
        update(id) { $0.state = .done }
        rates[id] = nil
        meters[id] = nil
        Announce.say(text)
        onChange?()
    }

    private func failed(_ id: String, _ error: Error) {
        let message = ConnectError.message(for: error)
        if ConnectError.isConnectionProblem(error) {
            update(id) {
                $0.state = .waiting
                $0.message = message
            }
            onConnectionProblem?(error)
            // Retry on a backoff too, in case nothing else notices the laptop coming back.
            let delay = min((retryDelay[id] ?? 2) * 2, 60)
            retryDelay[id] = delay
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.record(id)?.state == .waiting else { return }
                self.resume(id)
            }
        } else {
            update(id) {
                $0.state = .failed
                $0.message = message
            }
            rates[id] = nil
            if let r = record(id) { Announce.say("\(r.name) failed. \(message)") }
        }
    }

    // MARK: - Phone to PC

    private func startUploadWorker(_ id: String) {
        workers[id]?.cancel()
        workers[id] = Task { [weak self] in await self?.runUpload(id) }
    }

    private func sourceURL(_ r: TransferRecord) -> (URL, Bool)? {
        if let staged = r.stagedName {
            return (Self.stagingFolder.appendingPathComponent(staged), false)
        }
        guard let bookmark = r.sourceBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, url.startAccessingSecurityScopedResource())
    }

    private func removeStaged(_ r: TransferRecord) {
        if let staged = r.stagedName {
            try? FileManager.default.removeItem(at: Self.stagingFolder.appendingPathComponent(staged))
        }
    }

    private func runUpload(_ id: String) async {
        guard let client = clientProvider?(), var r = record(id) else { return }
        if let jobID = r.jobID {
            await followDriveJob(id, jobID, client)
            return
        }
        guard let source = sourceURL(r) else {
            failed(id, TransferError.sourceGone)
            return
        }
        let (url, scoped) = source
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if r.uploadID == nil {
                do {
                    let uploadID = try await client.uploadStart(folder: r.folder, name: r.name, size: r.size,
                                                                conflict: Conflict(rawValue: r.conflict) ?? .rename)
                    update(id) { $0.uploadID = uploadID }
                } catch ConnectError.notFound(_) {
                    // A server without resumable uploads: send it in one go.
                    try await simpleUpload(id, url, client)
                    return
                }
            }
            r = record(id) ?? r
            guard let uploadID = r.uploadID else { return }
            var offset: Int64
            do {
                offset = try await client.uploadStatus(uploadID)
            } catch ConnectError.notFound(_) {
                // The laptop swept the partial file; start over.
                update(id) {
                    $0.uploadID = nil
                    $0.done = 0
                }
                if !Task.isCancelled { startUploadWorker(id) }
                return
            }
            progressed(id, to: offset)
            while offset < r.size {
                try Task.checkCancellation()
                let length = Int(min(uploadChunkSize, r.size - offset))
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: length), !data.isEmpty else { throw TransferError.sourceGone }
                let base = offset
                let watcher = ChunkProgress { [weak self] sent in
                    Task { @MainActor in
                        guard let self, self.record(id)?.state == .running else { return }
                        self.progressed(id, to: base + sent)
                    }
                }
                offset = try await client.uploadChunk(uploadID, offset: offset, data: data, delegate: watcher)
                progressed(id, to: offset)
            }
            try Task.checkCancellation()
            update(id) { $0.state = .finishing }
            switch try await client.uploadFinish(uploadID) {
            case .path(let path):
                update(id) { $0.resultPath = path }
                removeStaged(r)
                retryDelay[id] = nil
                finished(id, "Sent \(r.name).")
            case .incomplete(let received):
                // Some bytes went missing on the way; pick up from what the laptop has.
                update(id) {
                    $0.state = .running
                    $0.done = received
                }
                if !Task.isCancelled { startUploadWorker(id) }
            case .job(let jobID):
                update(id) {
                    $0.jobID = jobID
                    $0.state = .sendingToDrive
                    $0.done = 0
                }
                removeStaged(r)
                meters[id] = nil
                await followDriveJob(id, jobID, client)
            }
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            failed(id, error)
        }
    }

    private func simpleUpload(_ id: String, _ url: URL, _ client: ConnectClient) async throws {
        guard let r = record(id), let request = client.uploadRequest(folder: r.folder, name: r.name, conflict: Conflict(rawValue: r.conflict) ?? .rename) else { return }
        let watcher = ChunkProgress { [weak self] sent in
            Task { @MainActor in self?.progressed(id, to: sent) }
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await ConnectClient.session.upload(for: request, fromFile: url, delegate: watcher)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw ConnectError.from(urlError: e, host: client.host)
        }
        let p: PathResult = try ConnectClient.decode(data, response)
        update(id) { $0.resultPath = p.path }
        removeStaged(r)
        finished(id, "Sent \(r.name).")
    }

    /// Second phase for a Drive folder: the laptop sends the file on to Google Drive.
    private func followDriveJob(_ id: String, _ jobID: String, _ client: ConnectClient) async {
        update(id) { $0.state = .sendingToDrive }
        while !Task.isCancelled {
            do {
                let job = try await client.job(jobID)
                if job.bytes > 0 { update(id) { $0.size = job.bytes } }
                progressed(id, to: job.bytesDone)
                if !job.isRunning {
                    if job.state == "done" && job.failed.isEmpty {
                        guard let name = record(id)?.name else { return }
                        finished(id, "Sent \(name) to Google Drive.")
                    } else {
                        update(id) {
                            $0.state = .failed
                            $0.message = job.message.isEmpty ? (job.failed.first?.error ?? "") : job.message
                        }
                        Announce.say(job.finishedText)
                    }
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if !ConnectError.isConnectionProblem(error) {
                    failed(id, error)
                    return
                }
                onConnectionProblem?(error)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - PC to phone

    private func partialURL(_ id: String) -> URL { Self.partialFolder.appendingPathComponent(id + ".part") }

    private func partialSize(_ id: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: partialURL(id).path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private func requestNextChunk(_ id: String) {
        guard let r = record(id), r.state == .running, let client = clientProvider?(), let url = client.fileURL(r.remotePath) else { return }
        let have = partialSize(id)
        if r.done != have { update(id) { $0.done = have } }
        var request = client.request(url, timeout: 60)
        if r.size > 0 {
            guard let range = TransferMath.nextChunk(offset: have, size: r.size, chunk: downloadChunkSize) else {
                completeDownload(id)
                return
            }
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        } else if have > 0 {
            // Unknown size: no safe way to append, so start over.
            try? FileManager.default.removeItem(at: partialURL(id))
        }
        engine.start(request, id: id, chunkStart: r.size > 0 ? have : 0)
    }

    private func downloadProgress(_ id: String, _ total: Int64) {
        guard record(id)?.state == .running else { return }
        progressed(id, to: total)
    }

    private func chunkFinished(_ id: String, _ start: Int64, _ file: URL?, _ status: Int, _ error: Error?) {
        guard let r = record(id) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            guard r.state == .running else { return }
            let e = (error as? URLError).map { ConnectError.from(urlError: $0, host: clientProvider?().host ?? "") } ?? error
            failed(id, e)
            return
        }
        guard r.state == .running else { return }
        if let failure = ConnectError.from(status: status) {
            failed(id, failure)
            return
        }
        guard let file else {
            failed(id, ConnectError.badResponse)
            return
        }
        let partial = partialURL(id)
        do {
            if status == 200 || start == 0 {
                // Whole file (a server that ignored Range, or the first piece): start the partial fresh.
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.moveItem(at: file, to: partial)
            } else {
                guard partialSize(id) == start else {
                    // Out of step (a chunk from before a pause): ask again from what we really have.
                    requestNextChunk(id)
                    return
                }
                let out = try FileHandle(forWritingTo: partial)
                defer { try? out.close() }
                try out.seekToEnd()
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
                    try out.write(contentsOf: block)
                }
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.message = "Couldn't save on the phone. \(error.localizedDescription)"
            }
            return
        }
        let have = partialSize(id)
        progressed(id, to: have)
        retryDelay[id] = nil
        if r.size <= 0 || status == 200 || have >= r.size {
            if r.size <= 0 { update(id) { $0.size = have } }
            completeDownload(id)
        } else {
            requestNextChunk(id)
        }
    }

    private func completeDownload(_ id: String) {
        guard let r = record(id) else { return }
        let fm = FileManager.default
        let name = TransferMath.uniqueName(r.name) { fm.fileExists(atPath: Self.documents.appendingPathComponent($0).path) }
        do {
            try fm.moveItem(at: partialURL(id), to: Self.documents.appendingPathComponent(name))
            update(id) { $0.savedName = name }
            finished(id, "Saved \(r.name) to iPhone.")
        } catch {
            update(id) {
                $0.state = .failed
                $0.message = "Couldn't save on the phone. \(error.localizedDescription)"
            }
        }
    }
}

enum TransferError: LocalizedError {
    case sourceGone
    var errorDescription: String? { "The file on the phone isn't there any more." }
}

/// Reports bytes sent for one upload request.
final class ChunkProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onSent: @Sendable (Int64) -> Void

    init(onSent: @escaping @Sendable (Int64) -> Void) {
        self.onSent = onSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }
}
