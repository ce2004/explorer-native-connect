import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    var code: String { didSet { defaults.set(code, forKey: Keys.code) } }
    /// True once a Connect has worked; until then the app opens on setup.
    var configured: Bool { didSet { defaults.set(configured, forKey: Keys.configured) } }
    var computerName: String { didSet { defaults.set(computerName, forKey: Keys.name) } }
    /// Bumped on every successful connect so the drive list reloads.
    private(set) var generation = 0

    let player = Player()
    let updater = Updater()

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let host = "host", code = "code", configured = "configured", name = "computerName"
    }

    init() {
        let args = ProcessInfo.processInfo.arguments
        let d = UserDefaults.standard
        if args.contains("-uitest-reset") {
            for k in [Keys.host, Keys.code, Keys.configured, Keys.name] { d.removeObject(forKey: k) }
        }
        if args.contains("-demo") {
            host = ConnectClient.demoHost
            code = "12345678"
            configured = true
            computerName = "Demo laptop"
        } else {
            host = d.string(forKey: Keys.host) ?? ConnectClient.defaultHost
            code = d.string(forKey: Keys.code) ?? ""
            configured = d.bool(forKey: Keys.configured)
            computerName = d.string(forKey: Keys.name) ?? ""
        }
        Downloader.clearOldFiles()
    }

    var client: ConnectClient { ConnectClient(host: host, code: code) }

    func connected(_ client: ConnectClient, info: ServerInfo) {
        host = client.host
        code = client.code
        computerName = info.name
        configured = true
        generation += 1
    }
}
