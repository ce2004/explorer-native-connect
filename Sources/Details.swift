import Foundation

// Pure logic for the Details screen, Test connection and the clipboard history. No network, no UI.

// MARK: - Flexible decoding

/// The laptop's numbers sometimes arrive as strings and its strings as numbers; take whichever comes.
extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "Yes" : "No" }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    func flexInt(_ key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        return flexDouble(key).flatMap { $0.isFinite ? Int64($0.rounded()) : nil }
    }

    func flexBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func flexDate(_ key: Key) -> Date? { flexString(key).flatMap(ISODate.parse) }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Rich /api/stat (v2.3)

struct NamedValue: Decodable, Equatable {
    var name: String
    var value: String

    private enum Keys: String, CodingKey { case name, value }

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = c.flexString(.name) ?? ""
        value = c.flexString(.value) ?? ""
    }
}

struct Chapter: Decodable, Equatable, Identifiable {
    var title: String
    var startSeconds: Double
    var id: Double { startSeconds }

    private enum Keys: String, CodingKey { case title, startSeconds }

    init(title: String, startSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = c.flexString(.title) ?? ""
        startSeconds = c.flexDouble(.startSeconds) ?? 0
    }
}

struct RichStat: Decodable {
    struct FileInfo: Decodable {
        var name, folder, ext, kind, mime, owner, driveWebLink, sha256: String?
        var size, sizeOnDisk: Int64?
        var created, modified, accessed: Date?
        var attributes: [String]
        var onDrive: Bool?

        private enum Keys: String, CodingKey {
            case name, folder, ext = "extension", kind, mime, owner, driveWebLink, sha256, size, sizeOnDisk, created, modified, accessed,
                 attributes, onDrive
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = c.flexString(.name)
            folder = c.flexString(.folder)
            ext = c.flexString(.ext)
            kind = c.flexString(.kind)
            mime = c.flexString(.mime)
            owner = c.flexString(.owner)
            driveWebLink = c.flexString(.driveWebLink)
            sha256 = c.flexString(.sha256)
            size = c.flexInt(.size)
            sizeOnDisk = c.flexInt(.sizeOnDisk)
            created = c.flexDate(.created)
            modified = c.flexDate(.modified)
            accessed = c.flexDate(.accessed)
            if let list = try? c.decodeIfPresent([String].self, forKey: .attributes) {
                attributes = list
            } else if let text = c.flexString(.attributes) {
                attributes = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            } else {
                attributes = []
            }
            onDrive = c.flexBool(.onDrive)
        }
    }

    struct FolderInfo: Decodable {
        var items, files, folders: Int64?
        private enum Keys: String, CodingKey { case items, files, folders }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            items = c.flexInt(.items)
            files = c.flexInt(.files)
            folders = c.flexInt(.folders)
        }
    }

    struct TextInfo: Decodable {
        var encoding, lineEndings, language: String?
        var bom: Bool?
        var lines, words, characters, charactersNoSpaces, paragraphs, blankLines, longestLine, nonAscii, tabs: Int64?
        private enum Keys: String, CodingKey {
            case encoding, lineEndings, language, bom, lines, words, characters, charactersNoSpaces, paragraphs, blankLines, longestLine,
                 nonAscii, tabs
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            encoding = c.flexString(.encoding)
            lineEndings = c.flexString(.lineEndings)
            language = c.flexString(.language)
            bom = c.flexBool(.bom)
            lines = c.flexInt(.lines)
            words = c.flexInt(.words)
            characters = c.flexInt(.characters)
            charactersNoSpaces = c.flexInt(.charactersNoSpaces)
            paragraphs = c.flexInt(.paragraphs)
            blankLines = c.flexInt(.blankLines)
            longestLine = c.flexInt(.longestLine)
            nonAscii = c.flexInt(.nonAscii)
            tabs = c.flexInt(.tabs)
        }
    }

    struct AudioStream: Decodable {
        var codec, codecProfile, channelLayout, language: String?
        var sampleRate, bitrate: Double?
        var bitsPerSample, channels: Int64?
        var vbr, lossless: Bool?
        private enum Keys: String, CodingKey {
            case codec, codecProfile, channelLayout, language, sampleRate, bitrate, bitsPerSample, channels, vbr, lossless
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            codec = c.flexString(.codec)
            codecProfile = c.flexString(.codecProfile)
            channelLayout = c.flexString(.channelLayout)
            language = c.flexString(.language)
            sampleRate = c.flexDouble(.sampleRate)
            bitrate = c.flexDouble(.bitrate)
            bitsPerSample = c.flexInt(.bitsPerSample)
            channels = c.flexInt(.channels)
            vbr = c.flexBool(.vbr)
            lossless = c.flexBool(.lossless)
        }
    }

    struct VideoStream: Decodable {
        var codec, hdr: String?
        var width, height: Int64?
        var frameRate, bitrate, rotation: Double?
        private enum Keys: String, CodingKey { case codec, hdr, width, height, frameRate, bitrate, rotation }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            codec = c.flexString(.codec)
            hdr = c.flexBool(.hdr).map { $0 ? "Yes" : "No" } ?? c.flexString(.hdr)
            width = c.flexInt(.width)
            height = c.flexInt(.height)
            frameRate = c.flexDouble(.frameRate)
            bitrate = c.flexDouble(.bitrate)
            rotation = c.flexDouble(.rotation)
        }
    }

    struct MediaInfo: Decodable {
        var container: String?
        var durationSeconds, bitrate, overallBitrate: Double?
        var audio: [AudioStream]
        var video: [VideoStream]
        var tags: [NamedValue]
        var chapters: [Chapter]
        var extra: [NamedValue]
        private enum Keys: String, CodingKey { case container, durationSeconds, bitrate, overallBitrate, audio, video, tags, chapters, extra }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            container = c.flexString(.container)
            durationSeconds = c.flexDouble(.durationSeconds)
            bitrate = c.flexDouble(.bitrate)
            overallBitrate = c.flexDouble(.overallBitrate)
            audio = (try? c.decodeIfPresent([AudioStream].self, forKey: .audio)) ?? []
            video = (try? c.decodeIfPresent([VideoStream].self, forKey: .video)) ?? []
            tags = Self.pairs(c, .tags)
            chapters = (try? c.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? []
            extra = Self.pairs(c, .extra)
        }

        /// `[{ name, value }]`, or a plain object as a fallback.
        private static func pairs(_ c: KeyedDecodingContainer<Keys>, _ key: Keys) -> [NamedValue] {
            if let list = try? c.decodeIfPresent([NamedValue].self, forKey: key) { return list }
            if let object = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key) {
                return object.allKeys.map { NamedValue(name: $0.stringValue, value: object.flexString($0) ?? "") }
                    .sorted { $0.name < $1.name }
            }
            return []
        }
    }

    struct ImageInfo: Decodable {
        var width, height, bitDepth: Int64?
        var format, dpi, camera, gps: String?
        var taken: Date?
        private enum Keys: String, CodingKey { case width, height, bitDepth, format, dpi, camera, gps, taken }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            width = c.flexInt(.width)
            height = c.flexInt(.height)
            bitDepth = c.flexInt(.bitDepth)
            format = c.flexString(.format)
            dpi = c.flexDouble(.dpi).map { DetailFormat.number($0) } ?? c.flexString(.dpi)
            camera = c.flexString(.camera)
            taken = c.flexDate(.taken)
            if let text = c.flexString(.gps) {
                gps = text
            } else if let o = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .gps) {
                let lat = ["lat", "latitude"].lazy.compactMap { o.flexDouble(AnyKey(stringValue: $0)) }.first
                let lon = ["lon", "lng", "longitude"].lazy.compactMap { o.flexDouble(AnyKey(stringValue: $0)) }.first
                if let lat, let lon { gps = String(format: "%.5f, %.5f", lat, lon) }
            }
        }
    }

    struct ArchiveInfo: Decodable {
        var entries, files, uncompressedSize: Int64?
        var format: String?
        private enum Keys: String, CodingKey { case entries, files, uncompressedSize, format }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            entries = c.flexInt(.entries)
            files = c.flexInt(.files)
            uncompressedSize = c.flexInt(.uncompressedSize)
            format = c.flexString(.format)
        }
    }

    var path: String?
    var file: FileInfo?
    var folderInfo: FolderInfo?
    var text: TextInfo?
    var media: MediaInfo?
    var image: ImageInfo?
    var archive: ArchiveInfo?
    var partial = false
    /// The short answer from a server before v2.3.
    var legacy: FileStat?
    /// The v2 `folder: true` the server still sends beside the sections.
    var folderFlag = false
    /// The v2 `tags` object, used when there's no media section to hold them.
    var oldTags: FileStat.Tags?

    private enum Keys: String, CodingKey { case path, file, folder, text, media, image, archive, partial, tags }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = c.flexString(.path)
        partial = c.flexBool(.partial) ?? false
        file = try? c.decodeIfPresent(FileInfo.self, forKey: .file)
        // In the old shape `folder` is true/false; in the new one it's the folder section.
        let flag = try? c.decodeIfPresent(Bool.self, forKey: .folder)
        folderFlag = flag == true
        folderInfo = flag == nil ? (try? c.decodeIfPresent(FolderInfo.self, forKey: .folder)) : nil
        text = try? c.decodeIfPresent(TextInfo.self, forKey: .text)
        media = try? c.decodeIfPresent(MediaInfo.self, forKey: .media)
        image = try? c.decodeIfPresent(ImageInfo.self, forKey: .image)
        archive = try? c.decodeIfPresent(ArchiveInfo.self, forKey: .archive)
        let rich = file != nil || folderInfo != nil || text != nil || media != nil || image != nil || archive != nil
        if !rich { legacy = try FileStat(from: decoder) }
        if rich && media == nil { oldTags = try? c.decodeIfPresent(FileStat.Tags.self, forKey: .tags) }
    }

    var isFolder: Bool { legacy?.folder ?? (folderInfo != nil || folderFlag) }
    var size: Int64? { legacy.map(\.size) ?? file?.size }
    var chapters: [Chapter] { media?.chapters ?? [] }
    var sha256: String? { file?.sha256 }
}

// MARK: - Formatting values for people

enum DetailFormat {
    static func number(_ n: Int64) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }

    /// Up to three decimals, trailing zeros dropped: 44.1, 48, 23.976.
    static func number(_ d: Double, decimals: Int = 3) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: d)) ?? String(d)
    }

    static func yesNo(_ b: Bool) -> String { b ? "Yes" : "No" }

    /// "4.2 MB, 4,404,019 bytes", or "812 bytes".
    static func size(_ bytes: Int64) -> String {
        bytes < 1024 ? Format.size(bytes) : "\(Format.size(bytes)), \(number(bytes)) bytes"
    }

    /// Bitrates in kbps ("320 kbps"), Mbps from 10,000 kbps up. A value under 5,000 is taken to be kbps already.
    static func bitrate(_ value: Double) -> String {
        guard value > 0, value.isFinite else { return "Unknown" }
        let kbps = value < 5000 ? value : value / 1000
        if kbps >= 10_000 { return "\(number(kbps / 1000, decimals: 1)) Mbps" }
        return "\(number(kbps.rounded(), decimals: 0)) kbps"
    }

    /// "44.1 kHz", "48 kHz".
    static func sampleRate(_ hz: Double) -> String {
        hz >= 1000 ? "\(number(hz / 1000)) kHz" : "\(number(hz, decimals: 0)) Hz"
    }

    /// "Mono", "Stereo", "5.1", "7.1", or "3 channels".
    static func channels(_ count: Int64?, layout: String?) -> String? {
        if let layout = layout?.trimmingCharacters(in: .whitespaces), !layout.isEmpty {
            let l = layout.lowercased()
            if l.contains("stereo") { return "Stereo" }
            if l.contains("mono") { return "Mono" }
            if let r = l.range(of: #"\d+\.\d"#, options: .regularExpression) { return String(l[r]) }
            if l == "quad" || l.contains("quadraphonic") { return "Quadraphonic" }
        }
        guard let count, count > 0 else { return layout }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) channels"
        }
    }

    static func attributes(_ list: [String]) -> String {
        let names = list.map { a -> String in
            switch a.lowercased() {
            case "readonly": return "Read-only"
            case "hidden": return "Hidden"
            case "system": return "System"
            case "archive": return "Archive"
            case "compressed": return "Compressed"
            case "offline": return "Offline"
            case "cloud": return "Cloud only"
            case "encrypted": return "Encrypted"
            case "temporary": return "Temporary"
            default: return capitalizedFirst(a)
            }
        }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// "Through a Tailscale relay in Chicago." for "relay ord"; "Direct connection." for "direct"; nil when unknown.
    static func path(_ path: String?) -> String? {
        guard let p = path?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        let lower = p.lowercased()
        if lower == "direct" { return "Direct connection." }
        if lower.hasPrefix("relay") {
            let region = p.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if region.isEmpty { return "Through a Tailscale relay." }
            return "Through a Tailscale relay in \(relayCity(region))."
        }
        return nil
    }

    /// Tailscale's DERP region codes as city names; anything else as it came.
    static func relayCity(_ code: String) -> String {
        let cities = [
            "nyc": "New York", "sfo": "San Francisco", "sin": "Singapore", "fra": "Frankfurt", "syd": "Sydney",
            "blr": "Bangalore", "tok": "Tokyo", "lhr": "London", "sao": "São Paulo", "dfw": "Dallas", "sea": "Seattle",
            "tor": "Toronto", "ord": "Chicago", "chi": "Chicago", "hkg": "Hong Kong", "par": "Paris", "mad": "Madrid",
            "jnb": "Johannesburg", "waw": "Warsaw", "mia": "Miami", "lax": "Los Angeles", "den": "Denver", "hnl": "Honolulu",
            "nai": "Nairobi", "dbi": "Dubai", "ams": "Amsterdam", "iad": "Ashburn", "atl": "Atlanta", "mex": "Mexico City",
        ]
        return cities[code.lowercased()] ?? code
    }
}

// MARK: - Details screen rows

struct DetailRow: Equatable {
    var label: String
    var value: String
    /// What VoiceOver says for the value when it differs from what's shown ("1 hour, 2 minutes" for "1:02:00").
    var spoken: String?

    init(_ label: String, _ value: String, spoken: String? = nil) {
        self.label = label
        self.value = value
        self.spoken = spoken
    }

    /// "Sample rate, 44.1 kHz": the row as one VoiceOver element.
    var accessibilityText: String { "\(label), \(spoken ?? value)" }
}

struct DetailSection: Equatable {
    var title: String
    var rows: [DetailRow]
}

enum DetailsBuilder {
    /// The sections to show, in order, leaving out whatever the laptop didn't send.
    static func sections(_ stat: RichStat, path: String) -> [DetailSection] {
        if let legacy = stat.legacy { return legacySections(legacy) }
        var out: [DetailSection] = []
        if stat.partial {
            out.append(DetailSection(title: "Note", rows: [DetailRow("Note", "Some details took too long to read and are missing.")]))
        }

        var file: [DetailRow] = []
        let f = stat.file
        let name = f?.name ?? RemotePath.lastComponent(path)
        file.append(DetailRow("Name", name))
        if let location = f?.folder ?? RemotePath.parent(path) { file.append(DetailRow("Location", location)) }
        if let kind = f?.kind, !kind.isEmpty {
            file.append(DetailRow("Kind", kind))
        } else {
            file.append(DetailRow("Kind", stat.isFolder ? "Folder" : FileKind.typeLabel(name)))
        }
        if let mime = f?.mime, !mime.isEmpty { file.append(DetailRow("MIME type", mime)) }
        if let folder = stat.folderInfo {
            var parts: [String] = []
            if let files = folder.files { parts.append(Format.count(Int(files), "file", "files")) }
            if let folders = folder.folders { parts.append(Format.count(Int(folders), "folder", "folders")) }
            if parts.isEmpty, let items = folder.items { parts.append(Format.count(Int(items), "item", "items")) }
            if !parts.isEmpty { file.append(DetailRow("Contains", parts.joined(separator: ", "))) }
        }
        if !stat.isFolder, let size = f?.size, size >= 0 { file.append(DetailRow("Size", DetailFormat.size(size))) }
        if let s = f?.sizeOnDisk, s >= 0, !stat.isFolder { file.append(DetailRow("Size on disk", DetailFormat.size(s))) }
        // Drive reports created as the same moment as modified; only show it when it says something.
        if let d = f?.created, abs(d.timeIntervalSince(f?.modified ?? .distantPast)) > 1 { file.append(DetailRow("Created", Format.date(d))) }
        if let d = f?.modified { file.append(DetailRow("Modified", Format.date(d))) }
        if let d = f?.accessed { file.append(DetailRow("Accessed", Format.date(d))) }
        let attributes = f?.attributes ?? []
        file.append(DetailRow("Read-only", DetailFormat.yesNo(attributes.contains { $0.lowercased() == "readonly" })))
        let others = attributes.filter { $0.lowercased() != "readonly" }
        if !others.isEmpty { file.append(DetailRow("Attributes", DetailFormat.attributes(others))) }
        if let owner = f?.owner, !owner.isEmpty { file.append(DetailRow("Owner", owner)) }
        if let onDrive = f?.onDrive { file.append(DetailRow("On Google Drive", DetailFormat.yesNo(onDrive))) }
        if let link = f?.driveWebLink, !link.isEmpty { file.append(DetailRow("Google Drive link", link)) }
        if let hash = f?.sha256, !hash.isEmpty { file.append(DetailRow("SHA-256", hash.lowercased())) }
        out.append(DetailSection(title: "File", rows: file))

        if let t = stat.text {
            var rows: [DetailRow] = []
            if let v = t.encoding { rows.append(DetailRow("Encoding", v)) }
            if let v = t.bom { rows.append(DetailRow("Byte order mark", DetailFormat.yesNo(v))) }
            if let v = t.lineEndings { rows.append(DetailRow("Line endings", v)) }
            let counts: [(String, Int64?)] = [
                ("Lines", t.lines), ("Words", t.words), ("Characters", t.characters),
                ("Characters without spaces", t.charactersNoSpaces), ("Paragraphs", t.paragraphs), ("Blank lines", t.blankLines),
            ]
            for (label, n) in counts { if let n { rows.append(DetailRow(label, DetailFormat.number(n))) } }
            if let n = t.longestLine { rows.append(DetailRow("Longest line", Format.count(Int(n), "character", "characters"))) }
            if let n = t.nonAscii { rows.append(DetailRow("Non-ASCII characters", DetailFormat.number(n))) }
            if let n = t.tabs { rows.append(DetailRow("Tabs", DetailFormat.number(n))) }
            if let v = t.language, !v.isEmpty { rows.append(DetailRow("Language", v)) }
            if !rows.isEmpty { out.append(DetailSection(title: "Text", rows: rows)) }
        }

        if stat.media == nil, let t = stat.oldTags {
            var rows: [DetailRow] = []
            if let v = t.title, !v.isEmpty { rows.append(DetailRow("Title", v)) }
            if let v = t.artist, !v.isEmpty { rows.append(DetailRow("Artist", v)) }
            if let v = t.album, !v.isEmpty { rows.append(DetailRow("Album", v)) }
            if let v = t.year, v > 0 { rows.append(DetailRow("Year", String(v))) }
            if let v = t.track, v > 0 { rows.append(DetailRow("Track", String(v))) }
            if let v = t.durationSeconds, v > 0 { rows.append(DetailRow("Duration", Format.time(v), spoken: Format.spokenTime(v))) }
            if !rows.isEmpty { out.append(DetailSection(title: "Tags", rows: rows)) }
        }

        if let m = stat.media {
            var rows: [DetailRow] = []
            if let v = m.container, !v.isEmpty { rows.append(DetailRow("Container", v)) }
            if let d = m.durationSeconds, d > 0 { rows.append(DetailRow("Duration", Format.time(d), spoken: Format.spokenTime(d))) }
            if let b = m.bitrate, b > 0 { rows.append(DetailRow("Bitrate", DetailFormat.bitrate(b))) }
            if let b = m.overallBitrate, b > 0 { rows.append(DetailRow("Overall bitrate", DetailFormat.bitrate(b))) }
            if !rows.isEmpty { out.append(DetailSection(title: "Media", rows: rows)) }

            for (i, a) in m.audio.enumerated() {
                var rows: [DetailRow] = []
                if let v = a.codec, !v.isEmpty { rows.append(DetailRow("Codec", v)) }
                if let v = a.codecProfile, !v.isEmpty { rows.append(DetailRow("Profile", v)) }
                if let v = a.sampleRate, v > 0 { rows.append(DetailRow("Sample rate", DetailFormat.sampleRate(v))) }
                if let v = a.bitsPerSample, v > 0 { rows.append(DetailRow("Bit depth", "\(v)-bit")) }
                if let v = DetailFormat.channels(a.channels, layout: a.channelLayout) { rows.append(DetailRow("Channels", v)) }
                if let v = a.bitrate, v > 0 { rows.append(DetailRow("Bitrate", DetailFormat.bitrate(v))) }
                if let v = a.vbr { rows.append(DetailRow("Variable bitrate", DetailFormat.yesNo(v))) }
                if let v = a.lossless { rows.append(DetailRow("Lossless", DetailFormat.yesNo(v))) }
                if let v = a.language, !v.isEmpty { rows.append(DetailRow("Language", v)) }
                let title = m.audio.count == 1 ? "Audio stream" : "Audio stream \(i + 1)"
                if !rows.isEmpty { out.append(DetailSection(title: title, rows: rows)) }
            }
            for (i, v) in m.video.enumerated() {
                var rows: [DetailRow] = []
                if let c = v.codec, !c.isEmpty { rows.append(DetailRow("Codec", c)) }
                if let w = v.width, let h = v.height, w > 0, h > 0 {
                    rows.append(DetailRow("Resolution", "\(w) × \(h)", spoken: "\(w) by \(h)"))
                }
                if let r = v.frameRate, r > 0 {
                    let n = DetailFormat.number(r)
                    rows.append(DetailRow("Frame rate", "\(n) fps", spoken: "\(n) frames per second"))
                }
                if let b = v.bitrate, b > 0 { rows.append(DetailRow("Bitrate", DetailFormat.bitrate(b))) }
                if let h = v.hdr, !h.isEmpty { rows.append(DetailRow("HDR", h)) }
                if let r = v.rotation, r != 0 {
                    let n = DetailFormat.number(r, decimals: 0)
                    rows.append(DetailRow("Rotation", "\(n)°", spoken: "\(n) degrees"))
                }
                let title = m.video.count == 1 ? "Video stream" : "Video stream \(i + 1)"
                if !rows.isEmpty { out.append(DetailSection(title: title, rows: rows)) }
            }
            let tags = m.tags.filter { !$0.name.isEmpty && !$0.value.isEmpty }.map { DetailRow(capitalizedFirst($0.name), $0.value) }
            if !tags.isEmpty { out.append(DetailSection(title: "Tags", rows: tags)) }
            let extra = m.extra.filter { !$0.name.isEmpty }.map { DetailRow(capitalizedFirst($0.name), $0.value) }
            if !extra.isEmpty { out.append(DetailSection(title: "Extra", rows: extra)) }
        }

        if let i = stat.image {
            var rows: [DetailRow] = []
            if let w = i.width, let h = i.height, w > 0, h > 0 { rows.append(DetailRow("Dimensions", "\(w) × \(h)", spoken: "\(w) by \(h)")) }
            if let v = i.format, !v.isEmpty { rows.append(DetailRow("Format", v)) }
            if let v = i.bitDepth, v > 0 { rows.append(DetailRow("Bit depth", "\(v)-bit")) }
            if let v = i.dpi, !v.isEmpty { rows.append(DetailRow("Resolution", "\(v) dpi", spoken: "\(v) dots per inch")) }
            if let v = i.camera, !v.isEmpty { rows.append(DetailRow("Camera", v)) }
            if let v = i.taken { rows.append(DetailRow("Taken", Format.date(v))) }
            if let v = i.gps, !v.isEmpty { rows.append(DetailRow("Location", v)) }
            if !rows.isEmpty { out.append(DetailSection(title: "Image", rows: rows)) }
        }

        if let a = stat.archive {
            var rows: [DetailRow] = []
            if let v = a.format, !v.isEmpty { rows.append(DetailRow("Format", v)) }
            if let v = a.entries { rows.append(DetailRow("Entries", DetailFormat.number(v))) }
            if let v = a.files { rows.append(DetailRow("Files", DetailFormat.number(v))) }
            if let v = a.uncompressedSize { rows.append(DetailRow("Uncompressed size", DetailFormat.size(v))) }
            if !rows.isEmpty { out.append(DetailSection(title: "Archive", rows: rows)) }
        }
        return out
    }

    /// An older server: the rows it always had, in a File section, with tags in their own.
    static func legacySections(_ stat: FileStat) -> [DetailSection] {
        let tagLabels: Set<String> = ["Title", "Artist", "Album", "Year", "Track", "Length"]
        let rows = stat.rows.map { DetailRow($0.0, $0.1) }
        var out = [DetailSection(title: "File", rows: rows.filter { !tagLabels.contains($0.label) })]
        let tags = rows.filter { tagLabels.contains($0.label) }
        if !tags.isEmpty { out.append(DetailSection(title: "Tags", rows: tags)) }
        return out
    }

    /// "Chapter 2, Middle, starts at 10 seconds".
    static func chapterLabel(_ c: Chapter, index: Int) -> String {
        let title = c.title.trimmingCharacters(in: .whitespaces)
        let name = title.isEmpty ? "Chapter \(index + 1)" : "Chapter \(index + 1), \(title)"
        return "\(name), starts at \(Format.spokenTime(c.startSeconds))"
    }

    /// Everything as plain text, for "Copy all details".
    static func plainText(title: String, sections: [DetailSection], chapters: [Chapter]) -> String {
        var lines = [title]
        for s in sections {
            lines.append("")
            lines.append(s.title)
            for r in s.rows { lines.append("\(r.label): \(r.value)") }
        }
        if !chapters.isEmpty {
            lines.append("")
            lines.append("Chapters")
            for (i, c) in chapters.enumerated() {
                lines.append("\(i + 1). \(c.title.isEmpty ? "Chapter \(i + 1)" : c.title), \(Format.time(c.startSeconds))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// SHA-256 is offered for files under 2 GB, on a server that can compute it.
    static func canHash(_ stat: RichStat, apiVersion: Int) -> Bool {
        guard apiVersion >= 4, stat.legacy == nil, !stat.isFolder, stat.sha256 == nil, let size = stat.size, size >= 0 else { return false }
        return size < 2 * 1024 * 1024 * 1024
    }
}

// MARK: - Test connection

struct PingResult: Decodable, Equatable {
    var time: Date?
    var path: String?

    private enum Keys: String, CodingKey { case time, path }

    init(time: Date? = nil, path: String? = nil) {
        self.time = time
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        time = c.flexDate(.time)
        path = c.flexString(.path)
    }
}

struct PingMeasurement: Equatable {
    var times: [Double]
    var path: String?

    /// The middle time, so one slow wake-up of the radio doesn't skew it.
    var typical: Double {
        let s = times.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// "Connected to CELAPTOP. Ping 38 ms (lowest 31, highest 52). Direct connection."
    func report(name: String) -> String {
        var text = name.isEmpty ? "Connected." : "Connected to \(name)."
        if !times.isEmpty {
            let ms = { (d: Double) in String(Int(d.rounded())) }
            text += " Ping \(ms(typical)) ms"
            if times.count > 1 { text += " (lowest \(ms(times.min() ?? 0)), highest \(ms(times.max() ?? 0)))" }
            text += "."
        }
        if let p = DetailFormat.path(path) { text += " " + p }
        return text
    }
}

// MARK: - Clipboard history

enum ClipHistory {
    /// What makes two entries the same thing: the same text, the same files, or (images) the same entry.
    static func contentKey(_ item: ClipboardItem) -> String {
        switch item.kind {
        case "text": return "text\u{1}" + (item.text ?? "")
        case "files": return "files\u{1}" + (item.files ?? []).map { $0.lowercased() }.joined(separator: "\u{1}")
        default: return "\(item.kind)\u{1}\(item.seq)"
        }
    }

    /// Newest first, each entry once: repeats of a seq and repeats of the same content keep only the newest.
    static func dedupe(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var seqs = Set<Int64>()
        var keys = Set<String>()
        var out: [ClipboardItem] = []
        for item in items.sorted(by: { $0.seq > $1.seq }) {
            guard seqs.insert(item.seq).inserted, keys.insert(contentKey(item)).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// The server's history plus anything the phone put there itself that the server doesn't keep. A server with a
    /// history (v2.2 and up) records what the phone sends, so the phone adds no echo of its own there.
    static func merge(server: [ClipboardItem], local: [ClipboardItem], serverKeepsHistory: Bool) -> [ClipboardItem] {
        dedupe(serverKeepsHistory ? server : server + local)
    }
}
