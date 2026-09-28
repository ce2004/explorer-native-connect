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

    static func symbol(for name: String) -> String {
        let e = ext(name)
        if audioExtensions.contains(e) { return "music.note" }
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
}

extension ServerInfo: Decodable {
    private enum Keys: String, CodingKey { case name, app, version }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }
}

struct Drive: Hashable {
    var name: String
    var label: String
    var kind: String
    var free: Int64
    var size: Int64

    /// "G:" from "G:\\".
    var letter: String {
        var n = name
        while n.count > 1 && n.hasSuffix("\\") { n.removeLast() }
        return n
    }
}

extension Drive: Decodable {
    private enum Keys: String, CodingKey { case name, label, kind, free, size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        free = try c.decodeIfPresent(Int64.self, forKey: .free) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    }
}

struct Entry: Hashable, Identifiable {
    var name: String
    var folder: Bool
    var size: Int64
    var modified: Date?

    var id: String { name }
}

extension Entry: Decodable {
    private enum Keys: String, CodingKey { case name, folder, size, modified }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decodeIfPresent(Bool.self, forKey: .folder) ?? false
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        modified = (try? c.decodeIfPresent(String.self, forKey: .modified)).flatMap { ISODate.parse($0) }
    }
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
}

// MARK: - What VoiceOver reads

enum Labels {
    /// "Albums, folder" or "song, 4.2 MB, FLAC".
    static func entry(_ e: Entry) -> String {
        if e.folder { return "\(e.name), folder" }
        return "\(FileKind.baseName(e.name)), \(Format.size(e.size)), \(FileKind.typeLabel(e.name))"
    }

    /// "Music, G:", "Local disk, C:", "Share, Z:, network drive".
    static func drive(_ d: Drive) -> String {
        let label = d.label.trimmingCharacters(in: .whitespaces)
        var parts = [label.isEmpty ? defaultLabel(d.kind) : label, d.letter]
        if let kind = kindText(d.kind) { parts.append(kind) }
        return parts.joined(separator: ", ")
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
        default: return "Local disk"
        }
    }

    private static func kindText(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "fixed", "": return nil
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
        default: return "internaldrive"
        }
    }
}

enum QueueBuilder {
    /// The tapped file followed by the audio files after it, in listing order.
    static func queue(from entries: [Entry], startingAt tapped: Entry) -> [Entry] {
        guard let i = entries.firstIndex(where: { $0.name == tapped.name }) else { return [tapped] }
        return [tapped] + entries[(i + 1)...].filter { !$0.folder && FileKind.isAudio($0.name) }
    }
}

enum Announce {
    /// Queued so it doesn't cut off whatever VoiceOver is saying.
    @MainActor static func say(_ text: String) {
        let s = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: s)
    }
}
