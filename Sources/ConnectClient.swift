import Foundation

enum ConnectError: LocalizedError, Equatable {
    case badComputerName
    /// The phone has no internet at all.
    case phoneOffline
    /// The name didn't resolve: Tailscale (MagicDNS) is off on the phone.
    case cantFind(String)
    /// Timed out: the laptop is off or asleep, or Tailscale is off somewhere.
    case notAnswering(String)
    /// Refused: the laptop is there but Explorer Native isn't listening.
    case appNotRunning(String)
    case wrongCode
    case notAllowed(String?)
    case notFound(String?)
    case nameTaken(String?)
    case driveNotMounted(String?)
    case oldServer
    case badRequest(String?)
    case server(Int, String?)
    case badResponse

    /// Maps a status (and the server's `{ "error": ... }` sentence) to an error; nil for success.
    static func from(status: Int, message: String? = nil) -> ConnectError? {
        let m = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = (m?.isEmpty ?? true) ? nil : m
        switch status {
        case 200...299: return nil
        case 400: return .badRequest(msg)
        case 401: return .wrongCode
        case 403: return .notAllowed(msg)
        case 404: return .notFound(msg)
        case 409: return .nameTaken(msg)
        case 503: return .driveNotMounted(msg)
        default: return .server(status, msg)
        }
    }

    static func from(urlError: URLError, host: String) -> ConnectError {
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .phoneOffline
        case .cannotFindHost, .dnsLookupFailed:
            return .cantFind(host)
        case .cannotConnectToHost:
            return .appNotRunning(host)
        default:
            return .notAnswering(host)
        }
    }

    /// The laptop couldn't be reached at all, as opposed to it answering with a problem.
    var isConnectionProblem: Bool {
        switch self {
        case .phoneOffline, .cantFind, .notAnswering, .appNotRunning: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .badComputerName:
            return "That computer name isn't valid."
        case .phoneOffline:
            return "The phone is offline."
        case .cantFind(let host):
            return "Can't find \(host). Make sure Tailscale is on, on the phone."
        case .notAnswering(let host):
            return "\(host) isn't answering. It may be off or asleep. Make sure Tailscale is on, on both the phone and the laptop."
        case .appNotRunning(let host):
            return "\(host) is on, but Explorer Native isn't answering. Make sure it's running."
        case .wrongCode:
            return "Wrong pairing code."
        case .notAllowed(let m):
            return m ?? "Windows won't allow that."
        case .notFound(let m):
            return m ?? "Can't open this. It may have moved, or Windows won't allow it."
        case .nameTaken(let m):
            return m ?? "That name is taken."
        case .driveNotMounted:
            return "Google Drive isn't available on the laptop. It may not be mounted, or it's signed out."
        case .oldServer:
            return "Explorer Native on the laptop needs updating for this."
        case .badRequest(let m):
            return m ?? "The laptop didn't understand that."
        case .server(let code, let m):
            return m ?? "The laptop had a problem (error \(code))."
        case .badResponse:
            return "The laptop sent something unexpected. Explorer Native may need updating."
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// What to say when a folder can't be measured: Drive gives up on huge folders with a 500.
    static func sizeMessage(for error: Error, name: String) -> String {
        if case .server(500, _)? = error as? ConnectError { return "\(name) is too big to measure." }
        return message(for: error)
    }

    static func isConnectionProblem(_ error: Error) -> Bool {
        (error as? ConnectError)?.isConnectionProblem ?? false
    }
}

enum Conflict: String, CaseIterable, Identifiable, Codable {
    case rename, skip, overwrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rename: return "Keep both"
        case .skip: return "Skip"
        case .overwrite: return "Replace"
        }
    }
}

struct ConnectClient: Sendable {
    static let port = 47810
    static let defaultHost = "laptop"

    let host: String
    let code: String
    let port: Int

    init(host: String, code: String, port: Int = ConnectClient.port) {
        self.host = Self.normalizeHost(host)
        self.code = Self.normalizeCode(code)
        self.port = port
    }

    static func normalizeHost(_ text: String) -> String {
        var h = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where h.lowercased().hasPrefix(scheme) {
            h = String(h.dropFirst(scheme.count))
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        // Drop a port ("laptop:47810") but leave IPv6 addresses alone.
        if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        return h.isEmpty ? defaultHost : h
    }

    /// Digits only: "1234 5678" and "1234-5678" both become "12345678".
    static func normalizeCode(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    var headers: [String: String] { ["X-Connect-Code": code] }

    func url(_ endpoint: String, path: String? = nil, query: [(String, String)] = []) -> URL? {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var s = "http://\(hostPart):\(port)/api/\(endpoint)"
        var pairs: [(String, String)] = []
        if let path { pairs.append(("path", path)) }
        pairs += query
        if !pairs.isEmpty {
            s += "?" + pairs.map { "\($0.0)=\(RemotePath.encode($0.1))" }.joined(separator: "&")
        }
        return URL(string: s)
    }

    func fileURL(_ path: String) -> URL? { url("file", path: path) }

    func request(_ url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue(code, forHTTPHeaderField: "X-Connect-Code")
        return r
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    // MARK: - Endpoints

    /// Short timeout: this is also the "is the laptop there" probe.
    func info(timeout: TimeInterval = 5) async throws -> ServerInfo {
        let client = self
        return try await Self.withDeadline(timeout + 1, host: host) {
            try await client.send("info", timeout: timeout)
        }
    }

    /// Runs `operation`, giving up with "not answering" after `seconds` whatever the URL loading system does.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, host: String,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ConnectError.notAnswering(host)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ConnectError.notAnswering(host) }
            return first
        }
    }

    func drives() async throws -> [Drive] {
        try await send("drives", timeout: 15)
    }

    /// Big Drive folders can take 45 seconds or so.
    func list(_ path: String) async throws -> [Entry] {
        try await send("list", path: path, timeout: 90)
    }

    func size(_ path: String) async throws -> FolderSize {
        try await send("size", path: path, timeout: 60)
    }

    /// Everything the laptop knows about a file (v2.3), or the short v2 answer from an older server.
    /// `hash` asks for the SHA-256 too, which takes a while for big files.
    func stat(_ path: String, hash: Bool = false) async throws -> RichStat {
        try await send("stat", path: path, query: hash ? [("hash", "1")] : [], timeout: hash ? 600 : 30)
    }

    /// The laptop's cheap "are you there" (v2.3): its time and how Tailscale reaches the phone.
    func ping(timeout: TimeInterval = 5) async throws -> PingResult {
        let client = self
        return try await Self.withDeadline(timeout + 1, host: host) {
            try await client.send("ping", timeout: timeout)
        }
    }

    /// About five round trips to /api/ping (or /api/info on an older server), timed.
    func measurePing(count: Int = 5, useInfo: Bool) async throws -> PingMeasurement {
        var times: [Double] = []
        var path: String?
        var lastError: Error?
        let clock = ContinuousClock()
        for _ in 0..<count {
            let start = clock.now
            do {
                if useInfo {
                    _ = try await info()
                } else {
                    path = try await ping().path ?? path
                }
                let d = clock.now - start
                times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if times.isEmpty { throw lastError ?? ConnectError.notAnswering(host) }
        return PingMeasurement(times: times, path: path)
    }

    /// Stops uploads that are on the wire (for "Stop all transfers"); ordinary requests carry on.
    static func cancelTransferTasks() {
        session.getAllTasks { tasks in
            for t in tasks {
                let path = t.originalRequest?.url?.path ?? ""
                if ["/api/upload/chunk", "/api/upload", "/api/clipboard/send"].contains(path) { t.cancel() }
            }
        }
    }

    func rename(_ path: String, to newName: String) async throws -> String {
        let r: PathResult = try await send("rename", method: "POST", body: ["path": path, "newName": newName])
        return r.path
    }

    func delete(_ paths: [String]) async throws -> DeleteResult {
        try await send("delete", method: "POST", body: ["paths": paths], timeout: 120)
    }

    func mkdir(in parent: String, name: String) async throws -> String {
        let r: PathResult = try await send("mkdir", method: "POST", body: ["parent": parent, "name": name])
        return r.path
    }

    func copy(_ paths: [String], to destination: String, conflict: Conflict, move: Bool) async throws -> String {
        let body = CopyBody(paths: paths, destination: destination, conflict: conflict.rawValue)
        let r: JobStarted = try await send(move ? "move" : "copy", method: "POST", body: body)
        return r.job
    }

    func job(_ id: String) async throws -> JobStatus {
        try await send("job", query: [("id", id)], timeout: 15)
    }

    func cancelJob(_ id: String) async throws {
        let _: OK = try await send("job/cancel", method: "POST", body: ["id": id])
    }

    func formats() async throws -> Formats {
        try await send("formats", timeout: 10)
    }

    /// Decoded to WAV on the laptop, for formats iOS can't play itself (and the audio of video files).
    func audioURL(_ path: String) -> URL? { url("audio", path: path) }

    // Resumable uploads (v2.1)

    enum FinishResult: Equatable {
        case path(String)
        case job(String)
        /// The laptop hasn't got every byte yet; carry on sending from here.
        case incomplete(Int64)
    }

    func uploadStart(folder: String, name: String, size: Int64, conflict: Conflict) async throws -> String {
        let body = UploadStartBody(folder: folder, name: name, size: size, conflict: conflict.rawValue)
        let r: IDResult = try await send("upload/start", method: "POST", body: body)
        return r.id
    }

    func uploadStatus(_ id: String) async throws -> Int64 {
        let r: Received = try await send("upload/status", query: [("id", id)], timeout: 15)
        return r.received
    }

    /// Sends one chunk; returns the total the laptop now holds. If the laptop holds a different amount than
    /// `offset` (a chunk got lost), returns that amount so the caller carries on from there.
    func uploadChunk(_ id: String, offset: Int64, data: Data, delegate: URLSessionTaskDelegate? = nil) async throws -> Int64 {
        guard let url = url("upload/chunk", query: [("id", id), ("offset", String(offset))]) else { throw ConnectError.badComputerName }
        var r = request(url, timeout: 60)
        r.httpMethod = "PUT"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let data2: Data
        let response: URLResponse
        do {
            (data2, response) = try await Self.session.upload(for: r, from: data, delegate: delegate)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw ConnectError.from(urlError: e, host: host)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let got = try? JSONDecoder().decode(Received.self, from: data2) {
            return got.received
        }
        let got: Received = try Self.decode(data2, response)
        return got.received
    }

    func uploadFinish(_ id: String) async throws -> FinishResult {
        guard let url = url("upload/finish") else { throw ConnectError.badComputerName }
        var r = request(url, timeout: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["id": id])
        let (data, response) = try await Self.perform(r, host: host)
        if let job = try? JSONDecoder().decode(JobStarted.self, from: data), (response as? HTTPURLResponse)?.statusCode == 202 {
            return .job(job.job)
        }
        if (response as? HTTPURLResponse)?.statusCode == 409, let got = try? JSONDecoder().decode(Received.self, from: data) {
            return .incomplete(got.received)
        }
        let p: PathResult = try Self.decode(data, response)
        return .path(p.path)
    }

    func uploadCancel(_ id: String) async throws {
        let _: OK = try await send("upload/cancel", method: "POST", body: ["id": id])
    }

    private struct UploadStartBody: Encodable {
        let folder: String
        let name: String
        let size: Int64
        let conflict: String
    }

    private struct IDResult: Decodable {
        let id: String
    }

    private struct Received: Decodable {
        let received: Int64
    }

    // Clipboard (v2.2)

    func clipboard() async throws -> ClipboardState {
        try await send("clipboard", timeout: 15)
    }

    /// Long poll: comes back when the clipboard changes, or after about 25 seconds as it was.
    func clipboardWait(since seq: Int64) async throws -> ClipboardState {
        try await send("clipboard/wait", query: [("since", String(seq))], timeout: 45)
    }

    func clipboardImage() async throws -> Data {
        guard let url = url("clipboard/image") else { throw ConnectError.badComputerName }
        let (data, response) = try await Self.perform(request(url, timeout: 30), host: host)
        if let failure = ConnectError.from(status: (response as? HTTPURLResponse)?.statusCode ?? 0) { throw failure }
        return data
    }

    @discardableResult
    func setClipboard(text: String) async throws -> Int64 {
        let r: SeqResult = try await send("clipboard", method: "POST", body: ["text": text])
        return r.seq ?? 0
    }

    func setClipboard(image: Data, contentType: String) async throws {
        guard let url = url("clipboard/image") else { throw ConnectError.badComputerName }
        var r = request(url, timeout: 60)
        r.httpMethod = "POST"
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = image
        let (data, response) = try await Self.perform(r, host: host)
        let _: Ignored = try Self.decode(data, response)
    }

    /// Puts files that are on the laptop on its clipboard, so Ctrl+V pastes them there.
    func copyOnPC(_ paths: [String]) async throws {
        let _: Ignored = try await send("clipboard/files", method: "POST", body: ["paths": paths])
    }

    func clipboardHistory() async throws -> [ClipboardItem] {
        try await send("clipboard/history", timeout: 15)
    }

    func clearClipboardHistory() async throws {
        let _: Ignored = try await send("clipboard/history/clear", method: "POST", body: [String: String]())
    }

    /// Sends one phone file for the PC clipboard; with a batch, it waits for `commitClipboardSend`.
    func clipboardSendRequest(name: String, batch: String?) -> URLRequest? {
        var query = [("name", name)]
        if let batch { query.append(("batch", batch)) }
        guard let url = url("clipboard/send", query: query) else { return nil }
        var r = request(url, timeout: 120)
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return r
    }

    func commitClipboardSend(batch: String) async throws {
        let _: Ignored = try await send("clipboard/send/commit", method: "POST", body: ["batch": batch])
    }

    /// Any JSON (or none) is fine; only the status matters.
    struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct SeqResult: Decodable {
        let seq: Int64?
    }

    func uploadRequest(folder: String, name: String, conflict: Conflict) -> URLRequest? {
        guard let url = url("upload", query: [("folder", folder), ("name", name), ("conflict", conflict.rawValue)]) else { return nil }
        var r = request(url, timeout: 120)
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return r
    }

    // MARK: - Plumbing

    private struct CopyBody: Encodable {
        let paths: [String]
        let destination: String
        let conflict: String
    }

    private struct OK: Decodable {}

    private struct ErrorBody: Decodable {
        let error: String
    }

    private func send<T: Decodable>(_ endpoint: String, path: String? = nil, query: [(String, String)] = [],
                                    method: String = "GET", body: (any Encodable)? = nil, timeout: TimeInterval = 20) async throws -> T {
        guard let url = url(endpoint, path: path, query: query) else { throw ConnectError.badComputerName }
        var r = request(url, timeout: timeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await Self.perform(r, host: host)
        return try Self.decode(data, response)
    }

    static func perform(_ request: URLRequest, host: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw ConnectError.from(urlError: e, host: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectError.notAnswering(host)
        }
    }

    static func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw ConnectError.badResponse }
        if let failure = ConnectError.from(status: http.statusCode, message: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error) {
            throw failure
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ConnectError.badResponse
        }
    }
}
