import Foundation
import Observation

/// Checks GitHub for a newer build. Installing is done from the PC with iloader, so this only tells you.
@MainActor
@Observable
final class Updater {
    static let sourceURL = URL(string: "https://github.com/ce2004/explorer-native-connect/releases/download/latest/source.json")!

    private(set) var availableBuild: Int?
    private(set) var checking = false
    private(set) var lastResult: String?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    /// When the signature iloader put on the app runs out.
    let signedUntil: Date? = ProvisionInfo.expiration()

    private struct Source: Decodable {
        struct App: Decodable {
            let versions: [Version]
        }
        struct Version: Decodable {
            let version: String
            let buildVersion: String?
        }
        let apps: [App]
    }

    func check(quiet: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let source = try JSONDecoder().decode(Source.self, from: data)
            guard let latest = source.apps.first?.versions.first,
                  let build = Int(latest.buildVersion ?? "") else {
                lastResult = "Couldn't read the update information."
                return
            }
            lastResult = Self.resultText(latest: build, current: currentBuild)
            availableBuild = build > currentBuild ? build : nil
        } catch {
            if !quiet { lastResult = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    nonisolated static func resultText(latest: Int, current: Int) -> String {
        latest > current ? "Build \(latest) is available. Install it from the PC with iloader." : "Explorer Connect is up to date."
    }

    /// "Signed until Oct 5"
    var signedText: String? {
        guard let signedUntil else { return nil }
        return "Signed until \(signedUntil.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Said once at launch when the signature is about to run out.
    var expiryWarning: String? { ProvisionInfo.warning(expires: signedUntil, now: Date()) }
}

/// Reads the embedded provisioning profile that iloader signs the app with.
enum ProvisionInfo {
    static func expiration() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expiration(from: data)
    }

    /// The profile is a signed blob with a plist inside; pull the plist out and read ExpirationDate.
    static func expiration(from data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// "Explorer Connect expires in 1 day. Reinstall it from the PC." when under two days are left.
    static func warning(expires: Date?, now: Date) -> String? {
        guard let expires else { return nil }
        let left = expires.timeIntervalSince(now)
        guard left < 2 * 86_400 else { return nil }
        if left <= 0 { return "Explorer Connect's signature has expired. Reinstall it from the PC." }
        let days = max(1, Int((left / 86_400).rounded(.up)))
        return "Explorer Connect expires in \(days == 1 ? "1 day" : "\(days) days"). Reinstall it from the PC."
    }
}
