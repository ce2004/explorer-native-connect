import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppModel {
    enum Link: Equatable {
        case unknown
        case online
        case offline(String)
    }

    var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    var code: String { didSet { defaults.set(code, forKey: Keys.code) } }
    /// True once a Connect has worked; until then the app opens on setup.
    var configured: Bool { didSet { defaults.set(configured, forKey: Keys.configured) } }
    var computerName: String { didSet { defaults.set(computerName, forKey: Keys.name) } }
    /// From /api/info; 1 means an old server without file actions.
    var apiVersion: Int { didSet { defaults.set(apiVersion, forKey: Keys.api) } }
    /// Which files are audio and which the laptop decodes for us.
    var formats: Formats {
        didSet {
            player.formats = formats
            if let data = try? JSONEncoder().encode(formats) { defaults.set(data, forKey: Keys.formats) }
        }
    }

    private(set) var link: Link = .unknown
    /// Bumped on every successful connect so the drive list reloads.
    private(set) var generation = 0
    /// Bumped when the laptop comes back after being unreachable.
    private(set) var onlineEpoch = 0
    /// Bumped after a change on the laptop (copy, move, delete...) so open folders reload.
    private(set) var changeEpoch = 0

    let settings = Settings()
    let player = Player()
    let updater = Updater()
    let jobs = JobCenter()
    let sizes = FolderSizes()
    let transfers = TransferCenter()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let portOverride: Int?
    @ObservationIgnored private var backoffTask: Task<Void, Never>?
    @ObservationIgnored private var checking: Task<Bool, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastCheck = Date.distantPast

    private enum Keys {
        static let host = "host", code = "code", configured = "configured", name = "computerName", api = "apiVersion", formats = "formats"
    }

    private static func arg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Test launch arguments, applied before anything reads its saved state:
    /// -uitest-reset wipes settings, saved lists, transfers and saved files; -host/-code set the computer;
    /// -port points at a different port (a closed one, to test being offline).
    static func prepareLaunch() {
        let args = ProcessInfo.processInfo.arguments
        let d = UserDefaults.standard
        if args.contains("-uitest-reset") {
            for k in [Keys.host, Keys.code, Keys.configured, Keys.name, Keys.api, Keys.formats, Player.savedKey, "repeatMode", "playbackSpeed"] + Settings.allKeys {
                d.removeObject(forKey: k)
            }
            ListingCache.clear()
            let fm = FileManager.default
            try? fm.removeItem(at: TransferCenter.baseFolder)
            for url in (try? fm.contentsOfDirectory(at: TransferCenter.documents, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
        if let h = arg("-host") {
            d.set(h, forKey: Keys.host)
            d.set(arg("-code") ?? "", forKey: Keys.code)
            d.set(true, forKey: Keys.configured)
        }
        if let chunk = arg("-chunk").flatMap(Int64.init) {
            d.set(chunk, forKey: "testChunkSize")
        } else {
            d.removeObject(forKey: "testChunkSize")
        }
    }

    init() {
        let d = UserDefaults.standard
        portOverride = Self.arg("-port").flatMap(Int.init)
        host = d.string(forKey: Keys.host) ?? ConnectClient.defaultHost
        code = d.string(forKey: Keys.code) ?? ""
        configured = d.bool(forKey: Keys.configured)
        computerName = d.string(forKey: Keys.name) ?? ""
        let api = d.integer(forKey: Keys.api)
        apiVersion = api > 0 ? api : 1
        formats = d.data(forKey: Keys.formats).flatMap { try? JSONDecoder().decode(Formats.self, from: $0) } ?? .fallback
        Downloader.clearOldFiles()

        applySettings()
        player.formats = formats
        transfers.clientProvider = { [weak self] in self?.client ?? ConnectClient(host: "", code: "") }
        transfers.onChange = { [weak self] in self?.changeEpoch += 1 }
        transfers.onConnectionProblem = { [weak self] error in self?.noteFailure(error) }
        let testChunk = Int64(d.integer(forKey: "testChunkSize"))
        if testChunk > 0 {
            transfers.uploadChunkSize = testChunk
            transfers.downloadChunkSize = testChunk
        }
        player.probe = { [weak self] in await self?.checkNow() ?? false }
        player.onConnectionLost = { [weak self] in self?.markOffline(ConnectError.notAnswering(self?.client.host ?? "")) }
        jobs.onChange = { [weak self] in self?.changeEpoch += 1 }
        jobs.onConnectionProblem = { [weak self] error in self?.noteFailure(error) }
        startPathMonitor()

        if configured && settings.resumePlayback, let saved = Player.loadSaved() {
            player.restore(saved, client: client)
        }
        if configured {
            transfers.resumeAfterLaunch()
            Task { await self.checkNow() }
        }
    }

    var client: ConnectClient { ConnectClient(host: host, code: code, port: portOverride ?? ConnectClient.port) }
    var isOnline: Bool { link == .online }
    var isOffline: Bool { if case .offline = link { return true } else { return false } }
    /// File actions need a v2 server that's answering.
    var canEdit: Bool { apiVersion >= 2 && !isOffline }

    func isAudio(_ name: String) -> Bool { formats.isAudio(name) }

    /// Pushes settings the player needs.
    func applySettings() {
        player.skipInterval = Double(settings.skipInterval)
        player.keepPlayingUntilReady = settings.keepPlayingUntilReady
        player.persistEnabled = settings.resumePlayback
        transfers.announceProgress = settings.announceTransfers
        if !settings.resumePlayback { Player.clearSaved() }
    }

    func connected(_ client: ConnectClient, info: ServerInfo) {
        let changedComputer = client.host != host
        host = client.host
        code = client.code
        computerName = info.name
        apiVersion = info.apiVersion
        configured = true
        player.updateClient(self.client)
        if changedComputer { ListingCache.clear() }
        setOnline()
        generation += 1
        Task { await refreshFormats() }
    }

    /// Asks the laptop which formats it plays. Old servers don't know; keep trying everything directly then.
    func refreshFormats() async {
        guard apiVersion >= 2 else {
            formats = .fallback
            return
        }
        if let f = try? await client.formats(), !f.audio.isEmpty || !f.native.isEmpty {
            if f != formats { formats = f }
        }
    }

    // MARK: - Reachability

    /// Asks the laptop if it's there. Returns true when it answered with the right code.
    @discardableResult
    func checkNow() async -> Bool {
        guard configured else { return false }
        if let checking { return await checking.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let client = self.client
            do {
                let info = try await client.info()
                self.apiVersion = info.apiVersion
                if !info.name.isEmpty { self.computerName = info.name }
                self.setOnline()
                await self.refreshFormats()
                return true
            } catch {
                self.noteFailure(error)
                return false
            }
        }
        checking = task
        let ok = await task.value
        checking = nil
        lastCheck = Date()
        return ok
    }

    /// When the app comes back to the front: check again unless we heard from the laptop just now.
    func appBecameActive() {
        guard configured else { return }
        if !isOnline || Date().timeIntervalSince(lastCheck) > 20 {
            Task { await checkNow() }
        }
    }

    /// Any request that succeeded proves the laptop is there.
    func noteSuccess() {
        if !isOnline { setOnline() }
    }

    /// Any request that failed: if it's a reachability problem, go offline and keep retrying.
    func noteFailure(_ error: Error) {
        guard let e = error as? ConnectError else { return }
        if e.isConnectionProblem {
            markOffline(e)
        } else if e == .wrongCode {
            link = .offline(e.errorDescription ?? "")
            backoffTask?.cancel()
        }
    }

    private func markOffline(_ error: ConnectError) {
        link = .offline(error.errorDescription ?? "")
        startBackoff()
    }

    private func setOnline() {
        backoffTask?.cancel()
        backoffTask = nil
        let wasOffline = !isOnline
        link = .online
        if wasOffline {
            onlineEpoch += 1
            player.connectionRestored()
            transfers.connectionRestored()
        }
    }

    private func startBackoff() {
        guard backoffTask == nil else { return }
        backoffTask = Task { [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if self.isOnline { break }
                if await self.checkNow() { break }
                delay = min(delay * 2, 60)
            }
            self?.backoffTask = nil
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.configured, !self.isOnline else { return }
                await self.checkNow()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "path-monitor"))
    }

    /// Runs a request, but if it's slow, checks in parallel that the laptop is still there, so a dead connection
    /// doesn't sit on "Loading" for a minute while a genuinely slow folder (big Drive folders) still gets its time.
    func watched<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let client = self.client
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                _ = try await client.info()
                try await Task.sleep(for: .seconds(3600))
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let value = result { return value }
            }
            throw ConnectError.notAnswering(client.host)
        }
    }
}
