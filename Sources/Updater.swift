import Foundation
import UIKit
import Observation

/// Checks GitHub for a newer build and hands it to SideStore, which installs it on the phone.
/// iOS apps can't replace themselves; SideStore can.
@MainActor
@Observable
final class Updater {
    struct Available: Equatable {
        let version: String
        let build: Int
        let downloadURL: URL
    }

    static let sourceURL = URL(string: "https://github.com/ce2004/explorer-native-connect/releases/download/latest/source.json")!

    private(set) var available: Available?
    private(set) var checking = false
    private(set) var lastResult: String?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    private struct Source: Decodable {
        struct App: Decodable {
            let bundleIdentifier: String
            let versions: [Version]
        }
        struct Version: Decodable {
            let version: String
            let buildVersion: String?
            let downloadURL: URL
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
            if build > currentBuild {
                available = Available(version: latest.version, build: build, downloadURL: latest.downloadURL)
                lastResult = "Version \(latest.version) is available."
            } else {
                available = nil
                lastResult = "Explorer Connect is up to date."
            }
        } catch {
            if !quiet { lastResult = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    /// Opens SideStore to install the new build.
    func install() async -> Bool {
        guard let available else { return false }
        return await openSideStore("install", available.downloadURL)
    }

    private func openSideStore(_ action: String, _ url: URL) async -> Bool {
        var c = URLComponents()
        c.scheme = "sidestore"
        c.host = action
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let link = c.url else { return false }
        let opened = await UIApplication.shared.open(link)
        if !opened { lastResult = "SideStore isn't installed, or isn't working. Install it with iloader first." }
        return opened
    }
}
