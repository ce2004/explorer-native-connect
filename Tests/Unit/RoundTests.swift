import XCTest
@testable import ExplorerConnect

final class ClipHistoryTests: XCTestCase {
    private func item(_ seq: Int64, _ kind: String, text: String? = nil, files: [String]? = nil) -> ClipboardItem {
        ClipboardItem(seq: seq, kind: kind, text: text, files: files)
    }

    func testRepeatsKeepOnlyTheNewest() {
        let items = [
            item(9, "text", text: "hello"),
            item(8, "text", text: "hello"),
            item(7, "files", files: ["C:\\A.txt"]),
            item(6, "files", files: ["c:\\a.txt"]),
            item(5, "image"),
            item(4, "image"),
            item(9, "text", text: "same seq twice"),
        ]
        let out = ClipHistory.dedupe(items)
        XCTAssertEqual(out.map(\.seq), [9, 7, 5, 4], "one per content (images are each their own) and one per seq")
        XCTAssertEqual(out.first?.text, "hello")
    }

    func testNoLocalEchoWhenTheServerKeepsHistory() {
        let server = [item(3, "text", text: "sent from the phone")]
        let local = [item(3, "text", text: "sent from the phone"), item(2, "text", text: "older echo")]
        XCTAssertEqual(ClipHistory.merge(server: server, local: local, serverKeepsHistory: true).map(\.seq), [3])
        XCTAssertEqual(ClipHistory.merge(server: [], local: local, serverKeepsHistory: false).map(\.seq), [3, 2])
        XCTAssertEqual(ClipHistory.merge(server: server, local: local, serverKeepsHistory: false).count, 2, "deduped by content when merging")
    }

    @MainActor
    func testLongPollOnlyWhileVisibleAndActive() {
        let clip = ClipboardModel()
        clip.clientProvider = { ConnectClient(host: "127.0.0.1", code: "12345678", port: 47899) }
        clip.setAppActive(true)
        XCTAssertFalse(clip.isWatching, "not until the tab shows")
        clip.setVisible(true)
        XCTAssertTrue(clip.isWatching)
        clip.setAppActive(false)
        XCTAssertFalse(clip.isWatching, "screen off or in the background: no long poll")
        clip.setAppActive(true)
        XCTAssertTrue(clip.isWatching)
        clip.setVisible(false)
        XCTAssertFalse(clip.isWatching, "another tab")
    }
}

final class PingTests: XCTestCase {
    func testReport() {
        let m = PingMeasurement(times: [52.2, 31, 38.4, 40, 36], path: "direct")
        XCTAssertEqual(m.typical, 38.4)
        XCTAssertEqual(m.report(name: "CELAPTOP"), "Connected to CELAPTOP. Ping 38 ms (lowest 31, highest 52). Direct connection.")
        let relay = PingMeasurement(times: [120, 130], path: "relay ord")
        XCTAssertEqual(relay.report(name: "CELAPTOP"), "Connected to CELAPTOP. Ping 125 ms (lowest 120, highest 130). Through a Tailscale relay in Chicago.")
        XCTAssertEqual(PingMeasurement(times: [5], path: nil).report(name: ""), "Connected. Ping 5 ms.")
        XCTAssertEqual(PingMeasurement(times: [5], path: "unknown").report(name: "X"), "Connected to X. Ping 5 ms.", "an unknown route isn't mentioned")
        XCTAssertEqual(DetailFormat.path("relay Somewhere"), "Through a Tailscale relay in Somewhere.")
    }

    func testDecoding() throws {
        let r = try JSONDecoder().decode(PingResult.self, from: Data(#"{"time":"2026-09-28T12:00:00Z","path":"relay nyc"}"#.utf8))
        XCTAssertEqual(r.path, "relay nyc")
        XCTAssertNotNil(r.time)
    }
}

final class DetailsTests: XCTestCase {
    private let richJSON = #"""
    {"path":"G:\\Books\\Long.m4b","partial":true,
     "file":{"name":"Long.m4b","folder":"G:\\Books","extension":".m4b","kind":"MPEG-4 audiobook","mime":"audio/mp4",
             "size":604241920,"sizeOnDisk":604246016,"created":"2026-01-02T03:04:05Z","modified":"2026-02-03T04:05:06Z",
             "accessed":"2026-09-28T12:00:00Z","attributes":["readOnly","hidden","cloud"],"owner":"CELAPTOP\\Conner",
             "onDrive":true,"driveWebLink":"https://drive.google.com/file/d/x"},
     "media":{"container":"MPEG-4","durationSeconds":36125.5,"bitrate":"128000","overallBitrate":129000,
              "audio":[{"codec":"AAC","codecProfile":"HE-AAC","sampleRate":44100,"bitsPerSample":16,"channels":2,"bitrate":64000,
                        "vbr":false,"lossless":false,"language":"eng"},
                       {"codec":"AC-3","sampleRate":"48000","channels":6,"channelLayout":"5.1(side)","bitrate":384}],
              "video":[{"codec":"H.264","width":1920,"height":1080,"frameRate":23.976,"bitrate":8000000,"hdr":false,"rotation":90}],
              "tags":[{"name":"Title","value":"A Long Book"},{"name":"track","value":"3 of 12"},{"name":"BPM","value":120}],
              "chapters":[{"title":"Opening","startSeconds":0},{"title":"","startSeconds":3725}],
              "extra":[{"name":"encoder delay","value":"2112"}]},
     "image":{"width":600,"height":400,"bitDepth":24,"format":"JPEG","dpi":72,"camera":"Pixel 9a","taken":"2026-05-01T10:00:00Z",
              "gps":{"lat":41.8781,"lon":-87.6298}},
     "archive":{"entries":12,"uncompressedSize":2048,"format":"ZIP"},
     "text":{"encoding":"UTF-8 with BOM","bom":true,"lineEndings":"CRLF","lines":1200,"words":5000,"characters":30000,
             "charactersNoSpaces":25000,"paragraphs":40,"blankLines":39,"longestLine":120,"nonAscii":3,"tabs":0,"language":"C#"}}
    """#

    private func rows(_ sections: [DetailSection], _ title: String) -> [String: String] {
        let s = sections.first { $0.title == title }
        return Dictionary((s?.rows ?? []).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    func testEverySectionFormattedForPeople() throws {
        let stat = try JSONDecoder().decode(RichStat.self, from: Data(richJSON.utf8))
        XCTAssertNil(stat.legacy)
        let sections = DetailsBuilder.sections(stat, path: "G:\\Books\\Long.m4b")
        XCTAssertEqual(sections.map(\.title), ["Note", "File", "Text", "Media", "Audio stream 1", "Audio stream 2", "Video stream",
                                               "Tags", "Extra", "Image", "Archive"])
        let file = rows(sections, "File")
        XCTAssertEqual(file["Name"], "Long.m4b")
        XCTAssertEqual(file["Location"], "G:\\Books")
        XCTAssertEqual(file["Kind"], "MPEG-4 audiobook")
        XCTAssertEqual(file["Size"], "576 MB, 604,241,920 bytes")
        XCTAssertEqual(file["Read-only"], "Yes")
        XCTAssertEqual(file["Attributes"], "Hidden, Cloud only")
        XCTAssertEqual(file["On Google Drive"], "Yes")
        XCTAssertEqual(file["Modified"], Format.date(ISODate.parse("2026-02-03T04:05:06Z")))

        let media = rows(sections, "Media")
        XCTAssertEqual(media["Duration"], "10:02:05")
        XCTAssertEqual(media["Bitrate"], "128 kbps")
        let duration = sections.first { $0.title == "Media" }!.rows.first { $0.label == "Duration" }!
        XCTAssertEqual(duration.accessibilityText, "Duration, 10 hours, 2 minutes, 5 seconds")

        let a1 = rows(sections, "Audio stream 1")
        XCTAssertEqual(a1["Sample rate"], "44.1 kHz")
        XCTAssertEqual(a1["Bit depth"], "16-bit")
        XCTAssertEqual(a1["Channels"], "Stereo")
        XCTAssertEqual(a1["Bitrate"], "64 kbps")
        XCTAssertEqual(a1["Profile"], "HE-AAC")
        XCTAssertEqual(a1["Lossless"], "No")
        let a2 = rows(sections, "Audio stream 2")
        XCTAssertEqual(a2["Sample rate"], "48 kHz")
        XCTAssertEqual(a2["Channels"], "5.1")
        XCTAssertEqual(a2["Bitrate"], "384 kbps", "a small number is already kbps")

        let v = rows(sections, "Video stream")
        XCTAssertEqual(v["Resolution"], "1920 × 1080")
        XCTAssertEqual(v["Frame rate"], "23.976 fps")
        XCTAssertEqual(v["Bitrate"], "8,000 kbps")
        XCTAssertEqual(v["Rotation"], "90°")
        let res = sections.first { $0.title == "Video stream" }!.rows.first { $0.label == "Resolution" }!
        XCTAssertEqual(res.accessibilityText, "Resolution, 1920 by 1080")

        XCTAssertEqual(rows(sections, "Tags")["Track"], "3 of 12")
        XCTAssertEqual(rows(sections, "Tags")["BPM"], "120")
        XCTAssertEqual(rows(sections, "Extra")["Encoder delay"], "2112")
        XCTAssertEqual(rows(sections, "Image")["Location"], "41.87810, -87.62980")
        XCTAssertEqual(rows(sections, "Image")["Resolution"], "72 dpi")
        XCTAssertEqual(rows(sections, "Archive")["Entries"], "12")
        XCTAssertEqual(rows(sections, "Text")["Lines"], "1,200")
        XCTAssertEqual(rows(sections, "Text")["Byte order mark"], "Yes")

        XCTAssertEqual(stat.chapters.count, 2)
        XCTAssertEqual(DetailsBuilder.chapterLabel(stat.chapters[1], index: 1), "Chapter 2, starts at 1 hour, 2 minutes, 5 seconds")
        XCTAssertEqual(DetailsBuilder.chapterLabel(stat.chapters[0], index: 0), "Chapter 1, Opening, starts at 0 seconds")

        let text = DetailsBuilder.plainText(title: "Long.m4b", sections: sections, chapters: stat.chapters)
        XCTAssertTrue(text.contains("Audio stream 1\nCodec: AAC"), text)
        XCTAssertTrue(text.contains("Chapters\n1. Opening, 0:00\n2. Chapter 2, 1:02:05"), text)
    }

    func testHashIsOfferedUnderTwoGigabytesOnNewServers() throws {
        let stat = try JSONDecoder().decode(RichStat.self, from: Data(richJSON.utf8))
        XCTAssertTrue(DetailsBuilder.canHash(stat, apiVersion: 4))
        XCTAssertFalse(DetailsBuilder.canHash(stat, apiVersion: 3))
        let big = try JSONDecoder().decode(RichStat.self, from: Data(#"{"file":{"name":"big.mkv","size":3000000000}}"#.utf8))
        XCTAssertFalse(DetailsBuilder.canHash(big, apiVersion: 4))
        let hashed = try JSONDecoder().decode(RichStat.self, from: Data(#"{"file":{"name":"a","size":3,"sha256":"ABC"}}"#.utf8))
        XCTAssertFalse(DetailsBuilder.canHash(hashed, apiVersion: 4))
        XCTAssertEqual(rows(DetailsBuilder.sections(hashed, path: "C:\\a"), "File")["SHA-256"], "abc")
    }

    func testFolderSectionAndOldServerFallback() throws {
        let folder = try JSONDecoder().decode(RichStat.self, from: Data(#"{"path":"T:\\Docs","file":{"name":"Docs"},"folder":{"items":5,"files":3,"folders":2}}"#.utf8))
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(rows(DetailsBuilder.sections(folder, path: "T:\\Docs"), "File")["Contains"], "3 files, 2 folders")

        let old = try JSONDecoder().decode(RichStat.self, from: Data(#"""
        {"path":"T:\\Music\\tone.flac","name":"tone.flac","folder":false,"size":173742,"modified":"2026-09-28T12:00:00Z",
         "readOnly":false,"onDrive":false,"tags":{"title":"Test Tone","artist":"Fake Server","durationSeconds":20.0}}
        """#.utf8))
        XCTAssertNotNil(old.legacy)
        XCTAssertFalse(old.isFolder)
        let sections = DetailsBuilder.sections(old, path: "T:\\Music\\tone.flac")
        XCTAssertEqual(sections.map(\.title), ["File", "Tags"])
        XCTAssertEqual(rows(sections, "File")["Read-only"], "No")
        XCTAssertEqual(rows(sections, "Tags")["Title"], "Test Tone")
        XCTAssertEqual(rows(sections, "Tags")["Length"], "20 seconds")
        XCTAssertFalse(DetailsBuilder.canHash(old, apiVersion: 4))
        let oldFolder = try JSONDecoder().decode(RichStat.self, from: Data(#"{"path":"T:\\Docs","name":"Docs","folder":true}"#.utf8))
        XCTAssertTrue(oldFolder.isFolder)
    }

    func testFormats() {
        XCTAssertEqual(DetailFormat.sampleRate(22050), "22.05 kHz")
        XCTAssertEqual(DetailFormat.sampleRate(96000), "96 kHz")
        XCTAssertEqual(DetailFormat.bitrate(320_000), "320 kbps")
        XCTAssertEqual(DetailFormat.bitrate(25_000_000), "25 Mbps")
        XCTAssertEqual(DetailFormat.channels(1, layout: nil), "Mono")
        XCTAssertEqual(DetailFormat.channels(8, layout: nil), "7.1")
        XCTAssertEqual(DetailFormat.channels(3, layout: nil), "3 channels")
        XCTAssertEqual(DetailFormat.channels(nil, layout: "Stereo"), "Stereo")
        XCTAssertEqual(DetailFormat.size(812), "812 bytes")
        XCTAssertEqual(DetailFormat.attributes([]), "None")
        XCTAssertEqual(Settings.cacheTitle(0), "Off")
        XCTAssertEqual(Settings.cacheTitle(2 << 30), "2 GB")
        XCTAssertEqual(Settings.cacheTitle(500 << 20), "500 MB")
    }
}

final class BlockStoreTests: XCTestCase {
    private func store(block: Int64 = 4) -> BlockStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blocks-\(UUID().uuidString)")
        return BlockStore(folder: dir, blockSize: block)
    }

    func testWritesReadsAndGaps() {
        let s = store()
        s.setMeta("a", total: 10, contentType: "public.mp3")
        XCTAssertEqual(s.fetchStart("a", need: 0), 0)
        XCTAssertTrue(s.write("a", at: 0, Data([0, 1, 2, 3, 4, 5])))
        XCTAssertEqual(s.contiguous("a", from: 0, limit: 100), 6)
        XCTAssertEqual(s.read("a", at: 2, count: 10), Data([2, 3, 4, 5]))
        XCTAssertFalse(s.write("a", at: 7, Data([7])), "bytes that don't follow on are refused")
        XCTAssertEqual(s.fetchStart("a", need: 7), 6, "a fetch starts where its block's bytes end")
        XCTAssertEqual(s.fetchStart("a", need: 3), 6, "a held byte needs nothing before the first gap")
        // A later block that already holds bytes stops a fetch there.
        XCTAssertTrue(s.write("a", at: 8, Data([8, 9])))
        XCTAssertEqual(s.fetchEnd("a", start: 6, maxLength: 100), 8)
        XCTAssertEqual(s.contiguous("a", from: 0, limit: 100), 6)
        XCTAssertTrue(s.write("a", at: 6, Data([6, 7])))
        XCTAssertTrue(s.isComplete("a"))
        XCTAssertEqual(s.read("a", at: 0, count: 10), Data(0..<10))
        XCTAssertNil(s.fetchStart("a", need: 0), "nothing to fetch")
        XCTAssertEqual(s.totalBytes, 10)
    }

    func testSurvivesRelaunch() {
        let s = store()
        s.setMeta("k", total: 6, contentType: "org.xiph.flac")
        s.write("k", at: 0, Data([1, 2, 3, 4, 5]))
        s.closeWriter()
        let again = BlockStore(folder: s.folder, blockSize: 4)
        XCTAssertEqual(again.totalBytes, 5)
        XCTAssertEqual(again.meta("k")?.total, 6)
        XCTAssertEqual(again.read("k", at: 0, count: 6), Data([1, 2, 3, 4, 5]))
    }

    func testEvictsLeastRecentlyUsedThenAroundTheReader() throws {
        let s = store()
        s.setMeta("old", total: 8, contentType: nil)
        s.write("old", at: 0, Data(repeating: 1, count: 8))
        Thread.sleep(forTimeInterval: 0.02)
        s.setMeta("new", total: 8, contentType: nil)
        s.write("new", at: 0, Data(repeating: 2, count: 8))
        Thread.sleep(forTimeInterval: 0.02)
        s.setMeta("playing", total: 40, contentType: nil)
        s.write("playing", at: 0, Data(repeating: 3, count: 40))
        XCTAssertEqual(s.totalBytes, 56)

        s.evict(capacity: 48, inUse: ["playing": 20], keepBehind: 4, keepAhead: 8)
        XCTAssertNil(s.meta("old"), "the least recently used file goes first")
        XCTAssertNotNil(s.meta("new"))
        XCTAssertEqual(s.totalBytes, 48)

        s.evict(capacity: 24, inUse: ["playing": 20], keepBehind: 4, keepAhead: 8)
        XCTAssertNil(s.meta("new"))
        XCTAssertLessThanOrEqual(s.totalBytes, 24)
        XCTAssertEqual(s.contiguous("playing", from: 16, limit: 100), 24, "what's just behind and ahead of the reader stays")
        XCTAssertFalse(s.isCached("playing", 0), "far behind the reader goes")
    }
}

@MainActor
final class ActivityTests: XCTestCase {
    func testWaitersResumeWhenTheAppComesBack() async {
        AppActivity.set(active: false)
        XCTAssertFalse(AppActivity.isActive)
        let t = Task { @MainActor () -> Date in
            await AppActivity.waitUntilActive()
            return Date()
        }
        try? await Task.sleep(for: .milliseconds(200))
        let comingBack = Date()
        AppActivity.set(active: true)
        let resumedAt = await t.value
        XCTAssertGreaterThanOrEqual(resumedAt, comingBack, "it waited for the app to come back")
    }
}
