import Foundation
import Observation

/// Preferences, saved as they change.
@MainActor
@Observable
final class Settings {
    // Browsing
    var sort: SortOrder { didSet { save(sort.rawValue, "sort") } }
    var foldersFirst: Bool { didSet { save(foldersFirst, "foldersFirst") } }
    var showExtensions: Bool { didSet { save(showExtensions, "showExtensions") } }
    var showFolderSizes: Bool { didSet { save(showFolderSizes, "showFolderSizes") } }

    // Playback
    var playWholeFolder: Bool { didSet { save(playWholeFolder, "playWholeFolder") } }
    var skipInterval: Int { didSet { save(skipInterval, "skipInterval") } }
    var resumePlayback: Bool { didSet { save(resumePlayback, "resumePlayback") } }
    var keepPlayingUntilReady: Bool { didSet { save(keepPlayingUntilReady, "keepPlayingUntilReady") } }

    // Files
    var conflict: Conflict { didSet { save(conflict.rawValue, "conflict") } }
    var confirmDelete: Bool { didSet { save(confirmDelete, "confirmDelete") } }
    var announceTransfers: Bool { didSet { save(announceTransfers, "announceTransfers") } }

    static let skipChoices = [10, 15, 30]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        sort = SortOrder(rawValue: defaults.string(forKey: "sort") ?? "") ?? .name
        foldersFirst = bool("foldersFirst", true)
        showExtensions = bool("showExtensions", false)
        showFolderSizes = bool("showFolderSizes", false)
        playWholeFolder = bool("playWholeFolder", true)
        let skip = defaults.integer(forKey: "skipInterval")
        skipInterval = Self.skipChoices.contains(skip) ? skip : 15
        resumePlayback = bool("resumePlayback", true)
        keepPlayingUntilReady = bool("keepPlayingUntilReady", true)
        conflict = Conflict(rawValue: defaults.string(forKey: "conflict") ?? "") ?? .rename
        confirmDelete = bool("confirmDelete", true)
        announceTransfers = bool("announceTransfers", true)
    }

    static let allKeys = ["sort", "foldersFirst", "showExtensions", "showFolderSizes", "playWholeFolder", "skipInterval",
                          "resumePlayback", "keepPlayingUntilReady", "conflict", "confirmDelete", "announceTransfers"]

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
