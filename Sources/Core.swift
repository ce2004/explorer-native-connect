import CryptoKit
import Foundation
import UIKit

// Pure logic shared by the app and the unit tests. Nothing here touches the network or the UI.

/// Windows paths as the server sees them: "G:\\", "G:\\Music\\Albums".
enum RemotePath {
    /// RFC 3986 unreserved characters only. Everything else, including + & = # ? % and spaces, is percent-encoded
    /// (URLComponents leaves '+' alone, which servers read as a space).
    static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func join(_ parent: String, _ name: String) -> String {
        if parent.isEmpty { return name }
        if parent.hasSuffix("\\") || parent.hasSuffix("/") { return parent + name }
        return parent + "\\" + name
    }

    /// "G:\\Music\\Albums" -> "Albums", "G:\\" -> "G:".
    static func lastComponent(_ path: String) -> String {
        var p = path
        while p.count > 1 && (p.hasSuffix("\\") || p.hasSuffix("/")) { p.removeLast() }
        if let i = p.lastIndex(where: { $0 == "\\" || $0 == "/" }) { return String(p[p.index(after: i)...]) }
        return p
    }

    /// "G:\\Music\\Albums" -> "G:\\Music"; a drive root has no parent.
    static func parent(_ path: String) -> String? {
        var p = path
        while p.count > 1 && p.hasSuffix("\\") { p.removeLast() }
        guard let i = p.lastIndex(of: "\\") else { return nil }
        let head = String(p[..<i])
        return head.hasSuffix(":") ? head + "\\" : head
    }

    /// Every folder from the drive root down to `path`: "G:\\a\\b" -> ["G:\\", "G:\\a", "G:\\a\\b"].
    static func ancestors(_ path: String) -> [String] {
        var chain: [String] = []
        var current: String? = path
        while let p = current {
            chain.insert(p, at: 0)
            current = parent(p)
        }
        return chain
    }

    /// True when `path` is `folder` or somewhere inside it (case-insensitive, like Windows).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = path.lowercased(), f = folder.lowercased()
        if p == f { return true }
        let prefix = f.hasSuffix("\\") ? f : f + "\\"
        return p.hasPrefix(prefix)
    }
}

enum Format {
    /// Sizes the way Windows counts them (1 KB = 1024 bytes): "1 byte", "812 bytes", "1.5 KB", "4.2 MB", "150 MB".
    static func size(_ bytes: Int64) -> String {
        let bytes = max(bytes, 0)
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        var text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        if text == "1024" && unit < units.count - 1 {
            text = "1"
            unit += 1
        }
        if text.hasSuffix(".0") { text.removeLast(2) }
        return "\(text) \(units[unit])"
    }

    /// "1:05", "1:02:03".
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1 minute, 5 seconds" for VoiceOver.
    static func spokenTime(_ seconds: Double) -> String {
        let t = seconds.isFinite ? max(0, seconds.rounded(.down)) : 0
        if t < 1 { return "0 seconds" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = t >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: t) ?? time(t)
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(number) \(n == 1 ? singular : plural)"
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum FileKind {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "alac", "opus", "ogg", "oga",
    ]

    /// Lowercased extension without the dot, or "" (".hidden" files have none).
    static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    static func baseName(_ name: String) -> String {
        guard !ext(name).isEmpty, let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    static func isAudio(_ name: String) -> Bool { audioExtensions.contains(ext(name)) }

    /// "FLAC", or "file" when there's no extension.
    static func typeLabel(_ name: String) -> String {
        let e = ext(name)
        return e.isEmpty ? "file" : e.uppercased()
    }

    static func symbol(for name: String, audio: Bool = false) -> String {
        let e = ext(name)
        if audio || audioExtensions.contains(e) { return "music.note" }
        switch e {
        case "jpg", "jpeg", "png", "gif", "heic", "bmp", "tif", "tiff", "webp": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv", "wmv": return "film"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log", "csv", "json", "xml", "ini": return "doc.plaintext"
        case "zip", "7z", "rar": return "doc.zipper"
        default: return "doc"
        }
    }
}

// MARK: - Server shapes

struct ServerInfo: Equatable {
    var name: String
    var app: String
    var version: Int
    var apiVersion: Int = 1
}

extension ServerInfo: Decodable {
    private enum Keys: String, CodingKey { case name, app, version, apiVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        apiVersion = (try? c.decodeIfPresent(Int.self, forKey: .apiVersion)) ?? 1
    }
}

struct Drive: Hashable, Codable {
    var name: String
    var label: String
    var kind: String
    var free: Int64
    var size: Int64
    var used: Int64 = 0
    var unlimited: Bool = false

    /// "G:" from "G:\\".
    var letter: String {
        var n = name
        while n.count > 1 && n.hasSuffix("\\") { n.removeLast() }
        return n
    }

    private enum Keys: String, CodingKey { case name, label, kind, free, size, used, unlimited }

    init(name: String, label: String, kind: String, free: Int64, size: Int64, used: Int64 = 0, unlimited: Bool = false) {
        self.name = name
        self.label = label
        self.kind = kind
        self.free = free
        self.size = size
        self.used = used
        self.unlimited = unlimited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        free = (try? c.decodeIfPresent(Int64.self, forKey: .free)) ?? 0
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        used = (try? c.decodeIfPresent(Int64.self, forKey: .used)) ?? max(0, size - free)
        unlimited = (try? c.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(label, forKey: .label)
        try c.encode(kind, forKey: .kind)
        try c.encode(free, forKey: .free)
        try c.encode(size, forKey: .size)
        try c.encode(used, forKey: .used)
        try c.encode(unlimited, forKey: .unlimited)
    }
}

struct Entry: Hashable, Identifiable, Codable {
    var name: String
    var folder: Bool
    /// Negative means unknown (Drive folders).
    var size: Int64
    var modified: Date?

    var id: String { name }
    var sizeKnown: Bool { size >= 0 && !folder }

    private enum Keys: String, CodingKey { case name, folder, size, modified }

    init(name: String, folder: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.folder = folder
        self.size = size
        self.modified = modified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        folder = (try? c.decodeIfPresent(Bool.self, forKey: .folder)) ?? false
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? -1
        modified = (try? c.decodeIfPresent(String.self, forKey: .modified)).flatMap { ISODate.parse($0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(folder, forKey: .folder)
        try c.encode(size, forKey: .size)
        if let modified { try c.encode(ISODate.string(modified), forKey: .modified) }
    }
}

struct FolderSize: Decodable, Equatable {
    var path: String
    var bytes: Int64
    var files: Int
    var folders: Int
    var complete: Bool

    private enum Keys: String, CodingKey { case path, bytes, files, folders, complete }

    init(path: String, bytes: Int64, files: Int, folders: Int, complete: Bool) {
        self.path = path
        self.bytes = bytes
        self.files = files
        self.folders = folders
        self.complete = complete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? 0
        files = (try? c.decodeIfPresent(Int.self, forKey: .files)) ?? 0
        folders = (try? c.decodeIfPresent(Int.self, forKey: .folders)) ?? 0
        complete = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? true
    }

    /// "4.2 GB" or "at least 4.2 GB".
    /// A drive root measures the account quota: bytes used, no counts.
    var isQuota: Bool { !complete && files == 0 && folders == 0 }

    var short: String {
        if isQuota { return "\(Format.size(bytes)) used" }
        return (complete ? "" : "at least ") + Format.size(bytes)
    }

    /// "4.2 GB, 1,203 files, 45 folders", prefixed "at least" when the walk ran out of time.
    var spoken: String {
        if isQuota { return short }
        return "\(short), \(Format.count(files, "file", "files")), \(Format.count(folders, "folder", "folders"))"
    }
}

struct FileStat: Decodable, Equatable {
    struct Tags: Decodable, Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var year: Int?
        var track: Int?
        var durationSeconds: Double?

        private enum Keys: String, CodingKey { case title, artist, album, year, track, durationSeconds }

        init(title: String? = nil, artist: String? = nil, album: String? = nil, year: Int? = nil, track: Int? = nil, durationSeconds: Double? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.year = year
            self.track = track
            self.durationSeconds = durationSeconds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            artist = try? c.decodeIfPresent(String.self, forKey: .artist)
            album = try? c.decodeIfPresent(String.self, forKey: .album)
            year = (try? c.decodeIfPresent(Int.self, forKey: .year)) ?? (try? c.decodeIfPresent(String.self, forKey: .year)).flatMap { Int($0) }
            track = (try? c.decodeIfPresent(Int.self, forKey: .track)) ?? (try? c.decodeIfPresent(String.self, forKey: .track)).flatMap { Int($0) }
            durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        }
    }

    var path: String
    var name: String
    var folder: Bool
    var size: Int64
    var modified: Date?
    var created: Date?
    var readOnly: Bool
    var onDrive: Bool
    var tags: Tags?

    private enum Keys: String, CodingKey { case path, name, folder, size, modified, created, readOnly, onDrive, tags }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? RemotePath.lastComponent(path)
        folder = (try? c.decodeIfPresent(Bool.self, forKey: .folder)) ?? false
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? -1
        modified = (try? c.decodeIfPresent(String.self, forKey: .modified)).flatMap { ISODate.parse($0) }
        created = (try? c.decodeIfPresent(String.self, forKey: .created)).flatMap { ISODate.parse($0) }
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        onDrive = (try? c.decodeIfPresent(Bool.self, forKey: .onDrive)) ?? false
        tags = try? c.decodeIfPresent(Tags.self, forKey: .tags)
    }

    /// The rows the Details screen shows, in order. Unknown values are left out.
    var rows: [(String, String)] {
        var r: [(String, String)] = [("Name", name)]
        if let parent = RemotePath.parent(path) { r.append(("Location", parent)) }
        r.append(("Type", folder ? "Folder" : FileKind.typeLabel(name)))
        if !folder && size >= 0 {
            let exact = NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)
            r.append(("Size", size < 1024 ? Format.size(size) : "\(Format.size(size)), \(exact) bytes"))
        }
        if let modified { r.append(("Modified", Format.date(modified))) }
        // Drive reports created as the same moment as modified; only show it when it says something.
        if let created, abs(created.timeIntervalSince(modified ?? .distantPast)) > 1 {
            r.append(("Created", Format.date(created)))
        }
        r.append(("Read-only", readOnly ? "Yes" : "No"))
        r.append(("On Google Drive", onDrive ? "Yes" : "No"))
        if let t = tags {
            if let v = t.title, !v.isEmpty { r.append(("Title", v)) }
            if let v = t.artist, !v.isEmpty { r.append(("Artist", v)) }
            if let v = t.album, !v.isEmpty { r.append(("Album", v)) }
            if let v = t.year, v > 0 { r.append(("Year", String(v))) }
            if let v = t.track, v > 0 { r.append(("Track", String(v))) }
            if let v = t.durationSeconds, v > 0 { r.append(("Length", Format.spokenTime(v))) }
        }
        return r
    }
}

struct JobStatus: Decodable, Equatable {
    struct Failure: Decodable, Equatable {
        var path: String
        var error: String
    }

    var id: String
    var kind: String
    var state: String
    var items: Int
    var itemsDone: Int
    var bytes: Int64
    var bytesDone: Int64
    var current: String
    var message: String
    var failed: [Failure]

    private enum Keys: String, CodingKey { case id, kind, state, items, itemsDone, bytes, bytesDone, current, message, failed }

    init(id: String, kind: String, state: String, items: Int = 0, itemsDone: Int = 0, bytes: Int64 = 0, bytesDone: Int64 = 0,
         current: String = "", message: String = "", failed: [Failure] = []) {
        self.id = id
        self.kind = kind
        self.state = state
        self.items = items
        self.itemsDone = itemsDone
        self.bytes = bytes
        self.bytesDone = bytesDone
        self.current = current
        self.message = message
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "running"
        items = (try? c.decodeIfPresent(Int.self, forKey: .items)) ?? 0
        itemsDone = (try? c.decodeIfPresent(Int.self, forKey: .itemsDone)) ?? 0
        bytes = (try? c.decodeIfPresent(Int64.self, forKey: .bytes)) ?? 0
        bytesDone = (try? c.decodeIfPresent(Int64.self, forKey: .bytesDone)) ?? 0
        current = (try? c.decodeIfPresent(String.self, forKey: .current)) ?? ""
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        failed = (try? c.decodeIfPresent([Failure].self, forKey: .failed)) ?? []
    }

    var isRunning: Bool { state == "running" }

    /// "Copying, 3 of 10 items, 1.2 GB of 4 GB"
    var progressText: String {
        let verb = kind == "move" ? "Moving" : kind == "upload" ? "Uploading" : "Copying"
        var parts = [verb]
        if items > 0 { parts.append("\(itemsDone) of \(Format.count(items, "item", "items"))") }
        if bytes > 0 { parts.append("\(Format.size(bytesDone)) of \(Format.size(bytes))") }
        return parts.joined(separator: ", ")
    }

    /// What to announce when the job stops.
    var finishedText: String {
        let noun = kind == "move" ? "Move" : kind == "upload" ? "Upload" : "Copy"
        switch state {
        case "done":
            if failed.isEmpty { return "\(noun) finished." }
            return "\(noun) finished. \(Format.count(failed.count, "item", "items")) failed: \(failed.first?.error ?? "")"
        case "cancelled": return "\(noun) cancelled."
        default: return "\(noun) failed. \(message)"
        }
    }
}

struct DeleteResult: Decodable, Equatable {
    var deleted: Int
    var failed: [JobStatus.Failure]

    private enum Keys: String, CodingKey { case deleted, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        deleted = (try? c.decodeIfPresent(Int.self, forKey: .deleted)) ?? 0
        failed = (try? c.decodeIfPresent([JobStatus.Failure].self, forKey: .failed)) ?? []
    }
}

struct PathResult: Decodable, Equatable {
    var path: String
}

struct JobStarted: Decodable, Equatable {
    var job: String
}

/// ISO 8601 with or without fractional seconds (any number of digits, as .NET writes seven) and with Z, an offset,
/// or no zone at all (read as UTC).
enum ISODate {
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var fraction = 0.0
        if let dot = s.firstIndex(of: "."), let t = s.firstIndex(of: "T"), dot > t {
            let digitsStart = s.index(after: dot)
            let end = s[digitsStart...].firstIndex(where: { !("0"..."9").contains($0) }) ?? s.endIndex
            fraction = Double("0." + String(s[digitsStart..<end])) ?? 0
            s.removeSubrange(dot..<end)
        }
        if let d = formatter.date(from: s) ?? formatter.date(from: s + "Z") {
            return d.addingTimeInterval(fraction)
        }
        return nil
    }

    static func string(_ date: Date) -> String {
        let whole = date.timeIntervalSince1970.rounded(.down)
        let base = formatter.string(from: Date(timeIntervalSince1970: whole))
        let ms = Int(((date.timeIntervalSince1970 - whole) * 1000).rounded())
        guard ms > 0, ms < 1000, base.hasSuffix("Z") else { return base }
        return String(base.dropLast()) + String(format: ".%03dZ", ms)
    }
}

// MARK: - Browsing preferences

enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case name, date, size, type
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date, newest first"
        case .size: return "Size, largest first"
        case .type: return "Type"
        }
    }
}

enum Sorter {
    static func sort(_ entries: [Entry], by order: SortOrder, foldersFirst: Bool) -> [Entry] {
        entries.sorted { a, b in
            if foldersFirst && a.folder != b.folder { return a.folder }
            switch order {
            case .name:
                break
            case .date:
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                if da != db { return da > db }
            case .size:
                if a.size != b.size { return a.size > b.size }
            case .type:
                let ea = FileKind.ext(a.name), eb = FileKind.ext(b.name)
                if ea != eb { return ea < eb }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - What VoiceOver reads

enum Labels {
    /// "Albums, folder", "song, 4.2 MB, FLAC", or with extensions shown "song.flac, 4.2 MB".
    static func entry(_ e: Entry, showExtensions: Bool = false, folderSize: FolderSize? = nil) -> String {
        if e.folder {
            if let folderSize { return "\(e.name), folder, \(folderSize.short)" }
            return "\(e.name), folder"
        }
        var parts = [showExtensions ? e.name : FileKind.baseName(e.name)]
        if e.sizeKnown { parts.append(Format.size(e.size)) }
        if !showExtensions { parts.append(FileKind.typeLabel(e.name)) }
        return parts.joined(separator: ", ")
    }

    static func displayName(_ e: Entry, showExtensions: Bool) -> String {
        e.folder || showExtensions ? e.name : FileKind.baseName(e.name)
    }

    /// "Music, G:, 1.2 TB free of 5 TB", "Local disk, C:", "Share, Z:, network drive, 10 GB free of 20 GB".
    static func drive(_ d: Drive) -> String {
        let label = d.label.trimmingCharacters(in: .whitespaces)
        var parts = [label.isEmpty ? defaultLabel(d.kind) : label, d.letter]
        if let kind = kindText(d.kind) { parts.append(kind) }
        if let space = space(d) { parts.append(space) }
        return parts.joined(separator: ", ")
    }

    /// "1.2 TB free of 5 TB", "Unlimited space", or nil when the size isn't known.
    static func space(_ d: Drive) -> String? {
        if d.unlimited { return "unlimited space" }
        guard d.size > 0 else { return nil }
        return "\(Format.size(d.free)) free of \(Format.size(d.size))"
    }

    /// Navigation title for a drive's root: "Music (G:)".
    static func driveTitle(_ d: Drive) -> String {
        let label = d.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? d.letter : "\(label) (\(d.letter))"
    }

    private static func defaultLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "network": return "Network"
        case "removable": return "USB drive"
        case "cdrom": return "CD drive"
        case "googledrive": return "Google Drive"
        default: return "Local disk"
        }
    }

    private static func kindText(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "fixed", "", "googledrive": return nil
        case "network": return "network drive"
        case "removable": return "removable"
        case "cdrom": return "CD"
        default: return kind.lowercased()
        }
    }

    static func driveSymbol(_ d: Drive) -> String {
        switch d.kind.lowercased() {
        case "network": return "server.rack"
        case "removable": return "externaldrive"
        case "cdrom": return "opticaldiscdrive"
        case "googledrive": return "icloud"
        default: return "internaldrive"
        }
    }
}

// MARK: - Queue

enum RepeatMode: String, CaseIterable, Codable, Identifiable {
    case off, one, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .one: return "This track"
        case .all: return "Whole queue"
        }
    }
}

enum QueueBuilder {
    /// The tapped file followed by the audio files after it, in listing order.
    static func queue(from entries: [Entry], startingAt tapped: Entry, wholeFolder: Bool = true,
                      isAudio: (String) -> Bool = FileKind.isAudio) -> [Entry] {
        guard wholeFolder, let i = entries.firstIndex(where: { $0.name == tapped.name }) else { return [tapped] }
        return [tapped] + entries[(i + 1)...].filter { !$0.folder && isAudio($0.name) }
    }

    /// Which track follows `index` when one ends. Repeat-one is handled by the player (it replays in place).
    static func next(after index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0 else { return nil }
        if index + 1 < count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    static func previous(before index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0 else { return nil }
        if index > 0 { return index - 1 }
        return repeatMode == .all ? count - 1 : nil
    }

    /// Keeps the current item first and shuffles the rest behind it.
    static func shuffled<T>(_ items: [T], current: Int) -> [T] {
        guard items.indices.contains(current) else { return items.shuffled() }
        var rest = items
        let first = rest.remove(at: current)
        return [first] + rest.shuffled()
    }
}

// MARK: - Saved listings for offline use

enum ListingCache {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Listings", isDirectory: true)
    }

    static func key(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.lowercased().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func save<T: Encodable>(_ value: T, for path: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = folder.appendingPathComponent(key(path) + ".json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, for path: String) -> T? {
        let url = folder.appendingPathComponent(key(path) + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    static let drivesKey = "::drives"
}

// MARK: - Formats

/// Which files are audio, and which of those need the laptop to decode them (/api/audio) instead of streaming as-is.
struct Formats: Codable, Equatable, Sendable {
    var audio: [String]
    var native: [String]

    static let builtInNative = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"]
    /// Before the laptop says (or with an old server): everything we know is tried directly.
    static let fallback = Formats(audio: FileKind.audioExtensions.sorted(), native: FileKind.audioExtensions.sorted())

    init(audio: [String], native: [String]) {
        self.audio = audio.map(Self.clean)
        self.native = native.map(Self.clean)
    }

    private enum Keys: String, CodingKey { case audio, native }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        audio = ((try? c.decodeIfPresent([String].self, forKey: .audio)) ?? []).map(Self.clean)
        let n = (try? c.decodeIfPresent([String].self, forKey: .native)) ?? Self.builtInNative
        native = n.map(Self.clean)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(audio, forKey: .audio)
        try c.encode(native, forKey: .native)
    }

    /// ".FLAC" -> "flac".
    static func clean(_ ext: String) -> String {
        var e = ext.trimmingCharacters(in: .whitespaces).lowercased()
        while e.hasPrefix(".") { e.removeFirst() }
        return e
    }

    func isAudio(_ name: String) -> Bool {
        let e = FileKind.ext(name)
        return !e.isEmpty && (audio.contains(e) || native.contains(e))
    }

    /// Plays through /api/audio (decoded to WAV on the laptop) rather than /api/file.
    func needsDecoding(_ name: String) -> Bool {
        isAudio(name) && !native.contains(FileKind.ext(name))
    }
}

// MARK: - Transfer maths

/// Smoothed transfer speed: an exponential moving average over about three seconds, so the number doesn't jump
/// around with every progress callback.
struct RateMeter: Equatable {
    private(set) var rate: Double = 0
    private var lastBytes: Int64?
    private var lastTime: TimeInterval = 0
    var timeConstant: Double = 3

    mutating func add(total bytes: Int64, at time: TimeInterval) {
        guard let previous = lastBytes else {
            lastBytes = bytes
            lastTime = time
            return
        }
        let dt = time - lastTime
        guard dt >= 0.25 else { return }
        let instant = max(0, Double(bytes - previous)) / dt
        let alpha = 1 - exp(-dt / timeConstant)
        rate = rate == 0 ? instant : rate + alpha * (instant - rate)
        lastBytes = bytes
        lastTime = time
    }

    /// Forget history (after a pause, or a new phase).
    mutating func reset() {
        rate = 0
        lastBytes = nil
    }

    func secondsLeft(remaining: Int64) -> Double? {
        guard rate > 1, remaining > 0 else { return nil }
        return Double(remaining) / rate
    }
}

enum TransferMath {
    static func percent(_ done: Int64, _ total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(100, max(0, Double(done) * 100 / Double(total))).rounded(.down))
    }

    /// The 10 % step just crossed going from `old` to `new` bytes, if any ("40" when passing 40 %). 100 isn't
    /// reported here; finishing gets its own announcement.
    static func crossedStep(from old: Int64, to new: Int64, total: Int64, step: Int = 10) -> Int? {
        let a = percent(old, total) / step, b = percent(new, total) / step
        guard b > a, b * step < 100 else { return nil }
        return b * step
    }

    /// "12 MB per second"
    static func speed(_ bytesPerSecond: Double) -> String {
        "\(Format.size(Int64(bytesPerSecond))) per second"
    }

    /// "2 minutes left", "less than a minute left"
    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        return (f.string(from: seconds) ?? "") + " left"
    }

    /// The byte range for the next chunk, or nil when done.
    static func nextChunk(offset: Int64, size: Int64, chunk: Int64) -> ClosedRange<Int64>? {
        guard offset < size, chunk > 0 else { return nil }
        return offset...min(size, offset + chunk) - 1
    }

    /// "song.flac", or "song (2).flac" when that's taken.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = FileKind.ext(name)
        let base = FileKind.baseName(name)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(name.split(separator: ".").last ?? "")"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}

// MARK: - Clipboard

/// What the PC clipboard holds.
struct ClipboardState: Decodable, Equatable {
    var seq: Int64
    var kind: String
    var text: String?
    var files: [String]?
    var imageBytes: Int64?

    private enum Keys: String, CodingKey { case seq, kind, text, files, imageBytes }

    init(seq: Int64, kind: String, text: String? = nil, files: [String]? = nil, imageBytes: Int64? = nil) {
        self.seq = seq
        self.kind = kind
        self.text = text
        self.files = files
        self.imageBytes = imageBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = (try? c.decodeIfPresent(Int64.self, forKey: .seq)) ?? 0
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "empty"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        files = try? c.decodeIfPresent([String].self, forKey: .files)
        imageBytes = try? c.decodeIfPresent(Int64.self, forKey: .imageBytes)
    }
}

/// One entry in the PC clipboard's history.
struct ClipboardItem: Decodable, Equatable, Identifiable {
    var seq: Int64
    var kind: String
    var text: String?
    var files: [String]?
    var time: Date?

    var id: Int64 { seq }

    private enum Keys: String, CodingKey { case seq, kind, text, files, time }

    init(seq: Int64, kind: String, text: String? = nil, files: [String]? = nil, time: Date? = nil) {
        self.seq = seq
        self.kind = kind
        self.text = text
        self.files = files
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = (try? c.decodeIfPresent(Int64.self, forKey: .seq)) ?? 0
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "empty"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        files = try? c.decodeIfPresent([String].self, forKey: .files)
        time = (try? c.decodeIfPresent(String.self, forKey: .time)).flatMap { ISODate.parse($0) }
    }
}

enum ClipText {
    /// The first `limit` characters with runs of whitespace (newlines too) squeezed to one space.
    static func preview(_ text: String, limit: Int = 60) -> String {
        let squeezed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard squeezed.count > limit else { return squeezed }
        return String(squeezed.prefix(limit)) + "…"
    }

    /// "3 files: a.txt, b.flac and 1 more"
    static func files(_ paths: [String]) -> String {
        let names = paths.map { RemotePath.lastComponent($0) }
        guard !names.isEmpty else { return "No files" }
        if names.count == 1 { return "1 file: \(names[0])" }
        let shown = names.prefix(2).joined(separator: ", ")
        let more = names.count - 2
        return "\(names.count) files: " + (more > 0 ? "\(shown) and \(more) more" : shown)
    }

    /// One line for a history row or an announcement.
    static func summary(kind: String, text: String?, files: [String]?) -> String {
        switch kind {
        case "text": return preview(text ?? "")
        case "files": return self.files(files ?? [])
        case "image": return "An image"
        default: return "Empty"
        }
    }

    /// "PC clipboard: <first 60 characters>", or nil when there's nothing worth saying.
    static func announcement(_ state: ClipboardState) -> String? {
        guard state.kind != "empty" else { return nil }
        return "PC clipboard: " + summary(kind: state.kind, text: state.text, files: state.files)
    }
}

enum Announce {
    /// Queued so it doesn't cut off whatever VoiceOver is saying.
    @MainActor static func say(_ text: String) {
        let s = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: s)
    }
}
