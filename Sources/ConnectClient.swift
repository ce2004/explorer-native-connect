import Foundation

enum ConnectError: LocalizedError, Equatable {
    case badComputerName
    case unreachable(String)
    case wrongCode
    case notFound
    case server(Int)
    case badResponse

    static func from(status: Int) -> ConnectError? {
        switch status {
        case 200...299: return nil
        case 401, 403: return .wrongCode
        case 404: return .notFound
        default: return .server(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .badComputerName: return "That computer name isn't valid."
        case .unreachable(let host): return "Can't reach \(host). Make sure Tailscale is on, on both the phone and the laptop."
        case .wrongCode: return "Wrong pairing code."
        case .notFound: return "Can't open this. It may have moved, or Windows won't allow it."
        case .server(let code): return "The laptop had a problem (error \(code))."
        case .badResponse: return "The laptop sent something unexpected. Explorer Native may need updating."
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct ConnectClient: Sendable {
    static let port = 47810
    static let defaultHost = "laptop"
    /// Launch with -demo to browse canned data (used by the UI tests).
    static let demoHost = "demo.invalid"

    let host: String
    let code: String

    init(host: String, code: String) {
        self.host = Self.normalizeHost(host)
        self.code = Self.normalizeCode(code)
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

    var isDemo: Bool { host == Self.demoHost }
    var headers: [String: String] { ["X-Connect-Code": code] }

    func url(_ endpoint: String, path: String? = nil) -> URL? {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var s = "http://\(hostPart):\(Self.port)/api/\(endpoint)"
        if let path { s += "?path=" + RemotePath.encode(path) }
        return URL(string: s)
    }

    func fileURL(_ path: String) -> URL? { url("file", path: path) }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(code, forHTTPHeaderField: "X-Connect-Code")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func info() async throws -> ServerInfo {
        if isDemo { return ServerInfo(name: "Demo laptop", app: "Explorer Native", version: 1) }
        return try await get("info")
    }

    func drives() async throws -> [Drive] {
        if isDemo { return Demo.drives }
        return try await get("drives")
    }

    func list(_ path: String) async throws -> [Entry] {
        if isDemo { return Demo.list(path) }
        return try await get("list", path: path)
    }

    private func get<T: Decodable>(_ endpoint: String, path: String? = nil) async throws -> T {
        guard let url = url(endpoint, path: path) else { throw ConnectError.badComputerName }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request(url))
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectError.unreachable(host)
        }
        guard let http = response as? HTTPURLResponse else { throw ConnectError.badResponse }
        if let failure = ConnectError.from(status: http.statusCode) { throw failure }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ConnectError.badResponse
        }
    }
}

enum Demo {
    static let drives = [
        Drive(name: "C:\\", label: "", kind: "Fixed", free: 100_000_000_000, size: 500_000_000_000),
        Drive(name: "G:\\", label: "Music", kind: "Fixed", free: 200_000_000_000, size: 1_000_000_000_000),
    ]

    static func list(_ path: String) -> [Entry] {
        if path.hasSuffix(":\\") {
            return [
                Entry(name: "Albums", folder: true, size: 0, modified: nil),
                Entry(name: "notes.txt", folder: false, size: 1229, modified: nil),
                Entry(name: "Song.flac", folder: false, size: 4_404_019, modified: nil),
            ]
        }
        return []
    }
}
