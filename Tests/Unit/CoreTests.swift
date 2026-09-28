import XCTest
@testable import ExplorerConnect

final class PathTests: XCTestCase {
    func testEncodesReservedCharactersAndSpaces() {
        XCTAssertEqual(
            RemotePath.encode("G:\\My Music\\a+b&c=d#e?f%g.flac"),
            "G%3A%5CMy%20Music%5Ca%2Bb%26c%3Dd%23e%3Ff%25g.flac"
        )
    }

    func testEncodesNonASCII() {
        XCTAssertEqual(RemotePath.encode("日本"), "%E6%97%A5%E6%9C%AC")
        XCTAssertEqual(RemotePath.encode("Café"), "Caf%C3%A9")
    }

    func testKeepsUnreservedCharacters() {
        XCTAssertEqual(RemotePath.encode("AZaz09-._~"), "AZaz09-._~")
    }

    func testURLRoundTripsThroughAQueryParser() throws {
        let path = "G:\\Music\\Rock & Roll\\1+1=2 #1? 100% 日本.flac"
        let client = ConnectClient(host: "laptop", code: "12345678")
        let url = try XCTUnwrap(client.url("list", path: path))
        XCTAssertTrue(url.absoluteString.hasPrefix("http://laptop:47810/api/list?path=G%3A%5CMusic"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.value, path)
    }

    func testQueryWithSeveralParameters() throws {
        let client = ConnectClient(host: "laptop", code: "12345678")
        let url = try XCTUnwrap(client.url("upload/chunk", query: [("id", "a&b"), ("offset", "8388608")]))
        XCTAssertEqual(url.absoluteString, "http://laptop:47810/api/upload/chunk?id=a%26b&offset=8388608")
    }

    func testJoin() {
        XCTAssertEqual(RemotePath.join("G:\\", "Music"), "G:\\Music")
        XCTAssertEqual(RemotePath.join("G:\\Music", "Albums"), "G:\\Music\\Albums")
        XCTAssertEqual(RemotePath.join("G:\\Music\\Albums", "Song.flac"), "G:\\Music\\Albums\\Song.flac")
        XCTAssertEqual(RemotePath.join("\\\\server\\share\\", "x"), "\\\\server\\share\\x")
    }

    func testLastComponentParentAndAncestors() {
        XCTAssertEqual(RemotePath.lastComponent("G:\\Music\\Albums"), "Albums")
        XCTAssertEqual(RemotePath.lastComponent("G:\\"), "G:")
        XCTAssertEqual(RemotePath.parent("G:\\Music\\Albums"), "G:\\Music")
        XCTAssertEqual(RemotePath.parent("G:\\Music"), "G:\\")
        XCTAssertNil(RemotePath.parent("G:\\"))
        XCTAssertEqual(RemotePath.ancestors("G:\\a\\b"), ["G:\\", "G:\\a", "G:\\a\\b"])
        XCTAssertEqual(RemotePath.ancestors("G:\\"), ["G:\\"])
    }

    func testIsInside() {
        XCTAssertTrue(RemotePath.isInside("G:\\Music\\A", "g:\\music"))
        XCTAssertTrue(RemotePath.isInside("G:\\Music", "G:\\Music"))
        XCTAssertFalse(RemotePath.isInside("G:\\Musical", "G:\\Music"))
        XCTAssertTrue(RemotePath.isInside("G:\\x", "G:\\"))
    }

    func testDestinationRules() {
        let move = PickRequest(paths: ["T:\\Music"], move: true)
        XCTAssertFalse(DestinationPicker.allowed("T:\\Music", move), "into itself")
        XCTAssertFalse(DestinationPicker.allowed("T:\\Music\\Sub", move), "into its own subfolder")
        XCTAssertFalse(DestinationPicker.allowed("T:\\", move), "moving to where it already is")
        XCTAssertTrue(DestinationPicker.allowed("T:\\Docs", move))
        let copy = PickRequest(paths: ["T:\\notes.txt"], move: false)
        XCTAssertTrue(DestinationPicker.allowed("T:\\", copy), "copying beside itself makes a copy")
    }
}

final class FormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(Format.size(0), "0 bytes")
        XCTAssertEqual(Format.size(1), "1 byte")
        XCTAssertEqual(Format.size(1023), "1023 bytes")
        XCTAssertEqual(Format.size(1024), "1 KB")
        XCTAssertEqual(Format.size(1536), "1.5 KB")
        XCTAssertEqual(Format.size(4_404_019), "4.2 MB")
        XCTAssertEqual(Format.size(150 * 1_048_576), "150 MB")
        XCTAssertEqual(Format.size(5 * 1_073_741_824), "5 GB")
        XCTAssertEqual(Format.size(1_048_575), "1 MB")
        XCTAssertEqual(Format.size(-5), "0 bytes")
    }

    func testTimes() {
        XCTAssertEqual(Format.time(0), "0:00")
        XCTAssertEqual(Format.time(65), "1:05")
        XCTAssertEqual(Format.time(3723), "1:02:03")
        XCTAssertEqual(Format.time(.nan), "0:00")
        XCTAssertEqual(Format.spokenTime(0), "0 seconds")
    }

    func testEntryLabels() {
        XCTAssertEqual(Labels.entry(Entry(name: "Albums", folder: true, size: 0, modified: nil)), "Albums, folder")
        XCTAssertEqual(Labels.entry(Entry(name: "Albums", folder: true, size: -1, modified: nil)), "Albums, folder")
        XCTAssertEqual(Labels.entry(Entry(name: "song.flac", folder: false, size: 4_404_019, modified: nil)), "song, 4.2 MB, FLAC")
        XCTAssertEqual(Labels.entry(Entry(name: "song.flac", folder: false, size: -1, modified: nil)), "song, FLAC", "unknown sizes are never spoken")
        XCTAssertEqual(Labels.entry(Entry(name: "song.flac", folder: false, size: 4_404_019, modified: nil), showExtensions: true), "song.flac, 4.2 MB")
        XCTAssertEqual(Labels.entry(Entry(name: "README", folder: false, size: 10, modified: nil)), "README, 10 bytes, file")
        let size = FolderSize(path: "x", bytes: 4_404_019, files: 3, folders: 0, complete: false)
        XCTAssertEqual(Labels.entry(Entry(name: "Albums", folder: true, size: 0, modified: nil), folderSize: size), "Albums, folder, at least 4.2 MB")
    }

    func testDriveLabels() {
        let tb: Int64 = 1_099_511_627_776
        let music = Drive(name: "G:\\", label: "Music", kind: "Fixed", free: tb * 12 / 10, size: tb * 5)
        XCTAssertEqual(Labels.drive(music), "Music, G:, 1.2 TB free of 5 TB")
        XCTAssertEqual(Labels.drive(Drive(name: "C:\\", label: "", kind: "Fixed", free: 0, size: 0)), "Local disk, C:")
        XCTAssertEqual(Labels.drive(Drive(name: "G:\\", label: "Google Drive", kind: "Fixed", free: 0, size: 0, unlimited: true)), "Google Drive, G:, unlimited space")
        XCTAssertEqual(Labels.drive(Drive(name: "Z:\\", label: "Share", kind: "Network", free: 10 * 1_073_741_824, size: 20 * 1_073_741_824)),
                       "Share, Z:, network drive, 10 GB free of 20 GB")
        XCTAssertEqual(Labels.driveTitle(music), "Music (G:)")
    }

    func testFolderSizeSpeech() {
        let partial = FolderSize(path: "G:\\Big", bytes: 4 * 1_073_741_824, files: 1203, folders: 45, complete: false)
        XCTAssertEqual(partial.spoken, "at least 4 GB, 1,203 files, 45 folders")
        let whole = FolderSize(path: "G:\\Small", bytes: 1024, files: 1, folders: 1, complete: true)
        XCTAssertEqual(whole.spoken, "1 KB, 1 file, 1 folder")
    }

    func testFileKinds() {
        for name in ["a.mp3", "a.M4A", "a.aac", "a.flac", "a.wav", "a.aif", "a.aiff", "a.caf", "a.alac", "a.opus", "a.ogg"] {
            XCTAssertTrue(FileKind.isAudio(name), name)
        }
        for name in ["a.txt", "a.jpg", "flac", ".flac", "a.mp4"] {
            XCTAssertFalse(FileKind.isAudio(name), name)
        }
        XCTAssertEqual(FileKind.baseName("my.song.flac"), "my.song")
    }

    func testFormatsFromServer() throws {
        let json = #"{"audio":[".flac",".OGG",".opus",".mp4",".mkv",".cda",".mp3"],"native":[".mp3",".m4a",".aac",".flac",".wav",".aif",".aiff",".caf",".alac"]}"#
        let f = try JSONDecoder().decode(Formats.self, from: Data(json.utf8))
        XCTAssertTrue(f.isAudio("a.flac"))
        XCTAssertFalse(f.needsDecoding("a.flac"))
        XCTAssertTrue(f.isAudio("video.MP4"))
        XCTAssertTrue(f.needsDecoding("video.mp4"), "video plays its sound through /api/audio")
        XCTAssertTrue(f.needsDecoding("a.ogg"))
        XCTAssertTrue(f.isAudio("a.wav"), "native formats count even if missing from audio")
        XCTAssertFalse(f.isAudio("notes.txt"))
        XCTAssertFalse(f.isAudio("noextension"))
        XCTAssertFalse(Formats.fallback.needsDecoding("a.opus"), "an old server gets everything tried directly")
    }

    func testSorting() {
        let d1 = Date(timeIntervalSince1970: 100), d2 = Date(timeIntervalSince1970: 200)
        let entries = [
            Entry(name: "b.txt", folder: false, size: 5, modified: d2),
            Entry(name: "Zeta", folder: true, size: 0, modified: d1),
            Entry(name: "a10.mp3", folder: false, size: 50, modified: d1),
            Entry(name: "a2.mp3", folder: false, size: 1, modified: d1),
            Entry(name: "Alpha", folder: true, size: 0, modified: d2),
        ]
        XCTAssertEqual(Sorter.sort(entries, by: .name, foldersFirst: true).map(\.name), ["Alpha", "Zeta", "a2.mp3", "a10.mp3", "b.txt"])
        XCTAssertEqual(Sorter.sort(entries, by: .name, foldersFirst: false).map(\.name), ["a2.mp3", "a10.mp3", "Alpha", "b.txt", "Zeta"])
        XCTAssertEqual(Sorter.sort(entries, by: .date, foldersFirst: true).map(\.name), ["Alpha", "Zeta", "b.txt", "a2.mp3", "a10.mp3"])
        XCTAssertEqual(Sorter.sort(entries, by: .size, foldersFirst: true).map(\.name), ["Alpha", "Zeta", "a10.mp3", "b.txt", "a2.mp3"])
        XCTAssertEqual(Sorter.sort(entries, by: .type, foldersFirst: true).map(\.name), ["Alpha", "Zeta", "a2.mp3", "a10.mp3", "b.txt"])
    }
}

final class ClientTests: XCTestCase {
    func testNormalizesCodeAndHost() {
        XCTAssertEqual(ConnectClient.normalizeCode("1234 5678"), "12345678")
        XCTAssertEqual(ConnectClient.normalizeCode("1234-5678"), "12345678")
        XCTAssertEqual(ConnectClient.normalizeHost(" http://laptop:47810/ "), "laptop")
        XCTAssertEqual(ConnectClient.normalizeHost("100.67.248.25"), "100.67.248.25")
        XCTAssertEqual(ConnectClient.normalizeHost(""), "laptop")
    }

    func testStatusMapping() {
        XCTAssertNil(ConnectError.from(status: 200))
        XCTAssertNil(ConnectError.from(status: 206))
        XCTAssertEqual(ConnectError.from(status: 401), .wrongCode)
        XCTAssertEqual(ConnectError.from(status: 404), .notFound(nil))
        XCTAssertEqual(ConnectError.from(status: 409, message: "That name is taken."), .nameTaken("That name is taken."))
        XCTAssertEqual(ConnectError.from(status: 403, message: " "), .notAllowed(nil))
        XCTAssertEqual(ConnectError.from(status: 503), .driveNotMounted(nil))
        XCTAssertEqual(ConnectError.from(status: 500, message: "Disk full."), .server(500, "Disk full."))
        XCTAssertEqual(ConnectError.server(500, "Disk full.").errorDescription, "Disk full.")
        XCTAssertTrue(ConnectError.driveNotMounted(nil).errorDescription!.contains("Google Drive"))
    }

    func testConnectionProblemsAreToldApart() {
        let offline = ConnectError.from(urlError: URLError(.notConnectedToInternet), host: "laptop")
        let dns = ConnectError.from(urlError: URLError(.cannotFindHost), host: "laptop")
        let timeout = ConnectError.from(urlError: URLError(.timedOut), host: "laptop")
        let refused = ConnectError.from(urlError: URLError(.cannotConnectToHost), host: "laptop")
        XCTAssertEqual(offline, .phoneOffline)
        XCTAssertEqual(dns, .cantFind("laptop"))
        XCTAssertEqual(timeout, .notAnswering("laptop"))
        XCTAssertEqual(refused, .appNotRunning("laptop"))
        for e in [offline, dns, timeout, refused] { XCTAssertTrue(e.isConnectionProblem) }
        for e: ConnectError in [.wrongCode, .driveNotMounted(nil), .oldServer, .notFound(nil)] { XCTAssertFalse(e.isConnectionProblem) }
        XCTAssertTrue(timeout.errorDescription!.contains("off or asleep"))
        XCTAssertTrue(timeout.errorDescription!.contains("Tailscale"))
        XCTAssertTrue(dns.errorDescription!.contains("Tailscale"))
        let all = [offline, dns, timeout, refused, .wrongCode, .driveNotMounted(nil), .oldServer].map { $0.errorDescription! }
        XCTAssertEqual(Set(all).count, all.count, "every problem sounds different")
    }

    func testFileURLAndHeaders() throws {
        let client = ConnectClient(host: "100.67.248.25", code: "1234 5678")
        let url = try XCTUnwrap(client.fileURL("G:\\Music\\a b.flac"))
        XCTAssertEqual(url.absoluteString, "http://100.67.248.25:47810/api/file?path=G%3A%5CMusic%5Ca%20b.flac")
        XCTAssertEqual(client.audioURL("G:\\v.mkv")?.absoluteString, "http://100.67.248.25:47810/api/audio?path=G%3A%5Cv.mkv")
        XCTAssertEqual(client.headers, ["X-Connect-Code": "12345678"])
        XCTAssertEqual(client.request(url).value(forHTTPHeaderField: "X-Connect-Code"), "12345678")
    }

    func testDeadlineGivesUp() async {
        let start = Date()
        do {
            _ = try await ConnectClient.withDeadline(0.3, host: "laptop") { () async throws -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("should have timed out")
        } catch {
            XCTAssertEqual(error as? ConnectError, .notAnswering("laptop"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

final class DecodingTests: XCTestCase {
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testInfo() throws {
        let v2 = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"LAPTOP","app":"Explorer Native","version":1,"apiVersion":2}"#.utf8))
        XCTAssertEqual(v2.apiVersion, 2)
        let v1 = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"LAPTOP","app":"Explorer Native","version":1}"#.utf8))
        XCTAssertEqual(v1, ServerInfo(name: "LAPTOP", app: "Explorer Native", version: 1, apiVersion: 1))
    }

    func testDrives() throws {
        let json = #"[{"name":"C:\\","label":"Windows","kind":"Fixed","free":123,"size":456},{"name":"G:\\","label":"Google Drive","kind":"Fixed","free":0,"size":0,"used":0,"unlimited":true}]"#
        let drives = try JSONDecoder().decode([Drive].self, from: Data(json.utf8))
        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives[0].name, "C:\\")
        XCTAssertEqual(drives[0].letter, "C:")
        XCTAssertEqual(drives[0].free, 123)
        XCTAssertEqual(drives[0].used, 333, "used is worked out when missing")
        XCTAssertTrue(drives[1].unlimited)
    }

    func testListWithDates() throws {
        let json = #"""
        [{"name":"Albums","folder":true,"size":-1,"modified":"2026-09-28T12:00:00Z"},
         {"name":"a.flac","folder":false,"size":4404019,"modified":"2026-09-28T12:00:00.5Z"},
         {"name":"b.flac","folder":false,"size":1,"modified":"2026-09-28T12:00:00.1234567Z"},
         {"name":"c.txt","folder":false,"size":2,"modified":"2026-09-28T14:00:00+02:00"},
         {"name":"d.txt","folder":false,"size":3,"modified":null},
         {"name":"e.txt","folder":false,"size":3}]
        """#
        let entries = try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.name), ["Albums", "a.flac", "b.flac", "c.txt", "d.txt", "e.txt"])
        XCTAssertTrue(entries[0].folder)
        XCTAssertEqual(entries[0].size, -1)
        XCTAssertFalse(entries[1].folder)
        XCTAssertEqual(entries[1].size, 4_404_019)
        let noon = date("2026-09-28T12:00:00Z")
        XCTAssertEqual(entries[0].modified, noon)
        XCTAssertEqual(entries[1].modified!.timeIntervalSince(noon), 0.5, accuracy: 0.001)
        XCTAssertEqual(entries[2].modified!.timeIntervalSince(noon), 0.1234567, accuracy: 0.001)
        XCTAssertEqual(entries[3].modified, noon)
        XCTAssertNil(entries[4].modified)
        XCTAssertNil(entries[5].modified)
    }

    func testDateWithoutZone() {
        XCTAssertEqual(ISODate.parse("2026-09-28T12:00:00"), date("2026-09-28T12:00:00Z"))
    }

    func testEntriesSurviveTheOfflineCache() throws {
        let entries = [
            Entry(name: "a.flac", folder: false, size: 10, modified: Date(timeIntervalSince1970: 1_790_000_000.25)),
            Entry(name: "Docs", folder: true, size: -1, modified: nil),
        ]
        let path = "T:\\Cache test \(UUID().uuidString)"
        ListingCache.save(entries, for: path)
        let back = try XCTUnwrap(ListingCache.load([Entry].self, for: path))
        XCTAssertEqual(back.map(\.name), ["a.flac", "Docs"])
        XCTAssertEqual(back[0].modified!.timeIntervalSince1970, 1_790_000_000.25, accuracy: 0.002)
        XCTAssertEqual(back[1].size, -1)
        XCTAssertNil(ListingCache.load([Entry].self, for: path + "x"))
        let drives = [Drive(name: "T:\\", label: "Test", kind: "Fixed", free: 1, size: 2, used: 1, unlimited: false)]
        ListingCache.save(drives, for: path + "drives")
        XCTAssertEqual(ListingCache.load([Drive].self, for: path + "drives"), drives)
    }

    func testSizeStatJobAndDelete() throws {
        let size = try JSONDecoder().decode(FolderSize.self, from: Data(#"{"path":"G:\\x","bytes":5,"files":2,"folders":1,"complete":false}"#.utf8))
        XCTAssertEqual(size, FolderSize(path: "G:\\x", bytes: 5, files: 2, folders: 1, complete: false))

        let stat = try JSONDecoder().decode(FileStat.self, from: Data(#"""
        {"path":"T:\\Music\\tone.flac","name":"tone.flac","folder":false,"size":173742,"modified":"2026-09-28T12:00:00Z",
         "created":"2026-09-27T12:00:00Z","readOnly":true,"onDrive":false,
         "tags":{"title":"Test Tone","artist":"Fake Server","album":"Fixtures","year":2026,"track":1,"durationSeconds":20.0}}
        """#.utf8))
        XCTAssertEqual(stat.tags?.title, "Test Tone")
        let rows = Dictionary(uniqueKeysWithValues: stat.rows.map { ($0.0, $0.1) })
        XCTAssertEqual(rows["Name"], "tone.flac")
        XCTAssertEqual(rows["Location"], "T:\\Music")
        XCTAssertEqual(rows["Type"], "FLAC")
        XCTAssertEqual(rows["Read-only"], "Yes")
        XCTAssertEqual(rows["Artist"], "Fake Server")
        XCTAssertEqual(rows["Album"], "Fixtures")
        XCTAssertEqual(rows["Year"], "2026")
        XCTAssertEqual(rows["Track"], "1")
        XCTAssertEqual(rows["Length"], "20 seconds")
        XCTAssertTrue(rows["Size"]!.contains("173,742 bytes"))

        let job = try JSONDecoder().decode(JobStatus.self, from: Data(#"""
        {"id":"j1","kind":"copy","state":"running","items":10,"itemsDone":3,"bytes":4294967296,"bytesDone":1288490189,"current":"a.flac","message":"","failed":[]}
        """#.utf8))
        XCTAssertEqual(job.progressText, "Copying, 3 of 10 items, 1.2 GB of 4 GB")
        var done = job
        done.state = "done"
        done.failed = [.init(path: "x", error: "Access denied.")]
        XCTAssertEqual(done.finishedText, "Copy finished. 1 item failed: Access denied.")

        let deleted = try JSONDecoder().decode(DeleteResult.self, from: Data(#"{"ok":true,"deleted":2,"failed":[{"path":"a","error":"Gone."}]}"#.utf8))
        XCTAssertEqual(deleted.deleted, 2)
        XCTAssertEqual(deleted.failed.first?.error, "Gone.")
    }
}

final class QueueTests: XCTestCase {
    private let entries = [
        Entry(name: "Bonus", folder: true, size: 0, modified: nil),
        Entry(name: "01 One.flac", folder: false, size: 1, modified: nil),
        Entry(name: "cover.jpg", folder: false, size: 1, modified: nil),
        Entry(name: "02 Two.mp3", folder: false, size: 1, modified: nil),
        Entry(name: "notes.txt", folder: false, size: 1, modified: nil),
        Entry(name: "03 Three.m4a", folder: false, size: 1, modified: nil),
        Entry(name: "04 Video.mkv", folder: false, size: 1, modified: nil),
    ]

    func testQueueStartsAtTappedAndKeepsLaterAudioInOrder() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[1]).map(\.name), ["01 One.flac", "02 Two.mp3", "03 Three.m4a"])
    }

    func testQueueUsesTheLaptopsFormats() {
        let formats = Formats(audio: ["flac", "mp3", "m4a", "mkv"], native: Formats.builtInNative)
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[3], isAudio: formats.isAudio).map(\.name),
                       ["02 Two.mp3", "03 Three.m4a", "04 Video.mkv"])
    }

    func testQueueSkipsEarlierTracks() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[3]).map(\.name), ["02 Two.mp3", "03 Three.m4a"])
    }

    func testSingleFileWhenFolderPlayIsOff() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[1], wholeFolder: false).map(\.name), ["01 One.flac"])
    }

    func testUnknownTrackQueuesOnlyItself() {
        let stray = Entry(name: "x.mp3", folder: false, size: 1, modified: nil)
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: stray).map(\.name), ["x.mp3"])
    }

    func testNextAndPreviousWithRepeat() {
        XCTAssertEqual(QueueBuilder.next(after: 0, count: 3, repeatMode: .off), 1)
        XCTAssertNil(QueueBuilder.next(after: 2, count: 3, repeatMode: .off))
        XCTAssertEqual(QueueBuilder.next(after: 2, count: 3, repeatMode: .all), 0)
        XCTAssertNil(QueueBuilder.next(after: 2, count: 3, repeatMode: .one), "repeat-one replays in place, it doesn't pick a next")
        XCTAssertNil(QueueBuilder.next(after: 0, count: 0, repeatMode: .all))
        XCTAssertEqual(QueueBuilder.previous(before: 0, count: 3, repeatMode: .all), 2)
        XCTAssertNil(QueueBuilder.previous(before: 0, count: 3, repeatMode: .off))
    }

    func testShuffleKeepsCurrentFirstAndEveryTrack() {
        let items = Array(0..<50)
        let shuffled = QueueBuilder.shuffled(items, current: 17)
        XCTAssertEqual(shuffled.first, 17)
        XCTAssertEqual(shuffled.sorted(), items)
    }

    func testSavedPlaybackRoundTrips() throws {
        let state = Player.SavedState(tracks: [Player.Track(name: "a.flac", path: "T:\\a.flac", folder: "T:")], index: 0, position: 42.5, playing: true)
        let back = try JSONDecoder().decode(Player.SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.tracks.map(\.path), ["T:\\a.flac"])
        XCTAssertEqual(back.index, 0)
        XCTAssertEqual(back.position, 42.5)
        XCTAssertTrue(back.playing)
    }
}

final class TransferMathTests: XCTestCase {
    func testRateIsSmoothed() {
        var meter = RateMeter()
        var bytes: Int64 = 0
        // A steady 1 MB/s with jittery ticks (0.3 MB then 0.7 MB per half second).
        for i in 0..<40 {
            bytes += i % 2 == 0 ? 314_573 : 734_003
            meter.add(total: bytes, at: Double(i + 1) * 0.5)
        }
        XCTAssertEqual(meter.rate, 1_048_576, accuracy: 1_048_576 * 0.25)
        let left = meter.secondsLeft(remaining: 10 * 1_048_576)
        XCTAssertNotNil(left)
        XCTAssertEqual(left ?? 0, 10, accuracy: 3)
        meter.reset()
        XCTAssertEqual(meter.rate, 0)
    }

    func testTenPercentSteps() {
        XCTAssertNil(TransferMath.crossedStep(from: 0, to: 9, total: 100))
        XCTAssertEqual(TransferMath.crossedStep(from: 9, to: 10, total: 100), 10)
        XCTAssertEqual(TransferMath.crossedStep(from: 15, to: 42, total: 100), 40)
        XCTAssertNil(TransferMath.crossedStep(from: 41, to: 49, total: 100))
        XCTAssertNil(TransferMath.crossedStep(from: 95, to: 100, total: 100), "finishing is announced separately")
        XCTAssertNil(TransferMath.crossedStep(from: 0, to: 50, total: 0))
    }

    func testChunks() {
        XCTAssertEqual(TransferMath.nextChunk(offset: 0, size: 20, chunk: 8), 0...7)
        XCTAssertEqual(TransferMath.nextChunk(offset: 16, size: 20, chunk: 8), 16...19)
        XCTAssertNil(TransferMath.nextChunk(offset: 20, size: 20, chunk: 8))
    }

    func testUniqueNames() {
        let taken: Set<String> = ["song.flac", "song (2).flac", "notes"]
        XCTAssertEqual(TransferMath.uniqueName("song.flac") { taken.contains($0) }, "song (3).flac")
        XCTAssertEqual(TransferMath.uniqueName("notes") { taken.contains($0) }, "notes (2)")
        XCTAssertEqual(TransferMath.uniqueName("new.txt") { taken.contains($0) }, "new.txt")
    }

    func testTransferDescriptions() {
        var r = TransferRecord(direction: .download, name: "big.mkv", size: 2_899_102_924)
        r.done = 1_288_490_189
        let text = TransferText.describe(r, rate: 12 * 1_048_576)
        XCTAssertTrue(text.hasPrefix("big.mkv, saving to iPhone, 44 percent, 1.2 GB of 2.7 GB, 12 MB per second"), text)
        XCTAssertTrue(text.hasSuffix("left"), text)
        r.state = .paused
        XCTAssertEqual(TransferText.describe(r, rate: 0), "big.mkv, paused, 44 percent, 1.2 GB of 2.7 GB")
        r.state = .done
        XCTAssertEqual(TransferText.describe(r, rate: 0), "big.mkv, saved to iPhone")
        var up = TransferRecord(direction: .upload, name: "a.mov", size: 100)
        up.state = .sendingToDrive
        up.done = 50
        XCTAssertEqual(TransferText.describe(up, rate: 0), "a.mov, sending to Google Drive, 50 percent, 50 bytes of 100 bytes")
        XCTAssertEqual(TransferMath.timeLeft(30), "less than a minute left")
    }

    func testRecordsSurviveRelaunch() throws {
        var r = TransferRecord(direction: .upload, name: "a.mov", size: 100)
        r.uploadID = "u1"
        r.folder = "T:\\Docs"
        let back = try JSONDecoder().decode([TransferRecord].self, from: JSONEncoder().encode([r]))
        XCTAssertEqual(back, [r])
    }
}
