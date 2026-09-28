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

    func testJoin() {
        XCTAssertEqual(RemotePath.join("G:\\", "Music"), "G:\\Music")
        XCTAssertEqual(RemotePath.join("G:\\Music", "Albums"), "G:\\Music\\Albums")
        XCTAssertEqual(RemotePath.join("G:\\Music\\Albums", "Song.flac"), "G:\\Music\\Albums\\Song.flac")
        XCTAssertEqual(RemotePath.join("\\\\server\\share\\", "x"), "\\\\server\\share\\x")
    }

    func testLastComponent() {
        XCTAssertEqual(RemotePath.lastComponent("G:\\Music\\Albums"), "Albums")
        XCTAssertEqual(RemotePath.lastComponent("G:\\"), "G:")
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
        XCTAssertEqual(Format.size(-5), "0 bytes")
    }

    func testTimes() {
        XCTAssertEqual(Format.time(0), "0:00")
        XCTAssertEqual(Format.time(65), "1:05")
        XCTAssertEqual(Format.time(3723), "1:02:03")
        XCTAssertEqual(Format.time(.nan), "0:00")
    }

    func testLabels() {
        XCTAssertEqual(Labels.entry(Entry(name: "Albums", folder: true, size: 0, modified: nil)), "Albums, folder")
        XCTAssertEqual(Labels.entry(Entry(name: "song.flac", folder: false, size: 4_404_019, modified: nil)), "song, 4.2 MB, FLAC")
        XCTAssertEqual(Labels.entry(Entry(name: "README", folder: false, size: 10, modified: nil)), "README, 10 bytes, file")
        XCTAssertEqual(Labels.drive(Drive(name: "G:\\", label: "Music", kind: "Fixed", free: 0, size: 0)), "Music, G:")
        XCTAssertEqual(Labels.drive(Drive(name: "C:\\", label: "", kind: "Fixed", free: 0, size: 0)), "Local disk, C:")
        XCTAssertEqual(Labels.drive(Drive(name: "Z:\\", label: "Share", kind: "Network", free: 0, size: 0)), "Share, Z:, network drive")
        XCTAssertEqual(Labels.driveTitle(Drive(name: "G:\\", label: "Music", kind: "Fixed", free: 0, size: 0)), "Music (G:)")
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
        XCTAssertEqual(ConnectError.from(status: 404), .notFound)
        XCTAssertEqual(ConnectError.from(status: 500), .server(500))
        XCTAssertTrue(ConnectError.unreachable("laptop").errorDescription!.contains("Tailscale"))
    }

    func testFileURLAndHeaders() throws {
        let client = ConnectClient(host: "100.67.248.25", code: "1234 5678")
        let url = try XCTUnwrap(client.fileURL("G:\\Music\\a b.flac"))
        XCTAssertEqual(url.absoluteString, "http://100.67.248.25:47810/api/file?path=G%3A%5CMusic%5Ca%20b.flac")
        XCTAssertEqual(client.headers, ["X-Connect-Code": "12345678"])
        XCTAssertEqual(client.request(url).value(forHTTPHeaderField: "X-Connect-Code"), "12345678")
    }
}

final class DecodingTests: XCTestCase {
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testInfo() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"LAPTOP","app":"Explorer Native","version":1}"#.utf8))
        XCTAssertEqual(info, ServerInfo(name: "LAPTOP", app: "Explorer Native", version: 1))
    }

    func testDrives() throws {
        let json = #"[{"name":"C:\\","label":"Windows","kind":"Fixed","free":123,"size":456},{"name":"G:\\","label":"Music","kind":"Network","free":5000000000000,"size":9000000000000}]"#
        let drives = try JSONDecoder().decode([Drive].self, from: Data(json.utf8))
        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives[0].name, "C:\\")
        XCTAssertEqual(drives[0].letter, "C:")
        XCTAssertEqual(drives[0].free, 123)
        XCTAssertEqual(drives[1].size, 9_000_000_000_000)
        XCTAssertEqual(drives[1].kind, "Network")
    }

    func testListWithDates() throws {
        let json = #"""
        [{"name":"Albums","folder":true,"size":0,"modified":"2026-09-28T12:00:00Z"},
         {"name":"a.flac","folder":false,"size":4404019,"modified":"2026-09-28T12:00:00.5Z"},
         {"name":"b.flac","folder":false,"size":1,"modified":"2026-09-28T12:00:00.1234567Z"},
         {"name":"c.txt","folder":false,"size":2,"modified":"2026-09-28T14:00:00+02:00"},
         {"name":"d.txt","folder":false,"size":3,"modified":null},
         {"name":"e.txt","folder":false,"size":3}]
        """#
        let entries = try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.name), ["Albums", "a.flac", "b.flac", "c.txt", "d.txt", "e.txt"])
        XCTAssertTrue(entries[0].folder)
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
}

final class QueueTests: XCTestCase {
    private let entries = [
        Entry(name: "Bonus", folder: true, size: 0, modified: nil),
        Entry(name: "01 One.flac", folder: false, size: 1, modified: nil),
        Entry(name: "cover.jpg", folder: false, size: 1, modified: nil),
        Entry(name: "02 Two.mp3", folder: false, size: 1, modified: nil),
        Entry(name: "notes.txt", folder: false, size: 1, modified: nil),
        Entry(name: "03 Three.m4a", folder: false, size: 1, modified: nil),
    ]

    func testQueueStartsAtTappedAndKeepsLaterAudioInOrder() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[1]).map(\.name), ["01 One.flac", "02 Two.mp3", "03 Three.m4a"])
    }

    func testQueueSkipsEarlierTracks() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[3]).map(\.name), ["02 Two.mp3", "03 Three.m4a"])
    }

    func testLastTrackQueuesOnlyItself() {
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: entries[5]).map(\.name), ["03 Three.m4a"])
    }

    func testUnknownTrackQueuesOnlyItself() {
        let stray = Entry(name: "x.mp3", folder: false, size: 1, modified: nil)
        XCTAssertEqual(QueueBuilder.queue(from: entries, startingAt: stray).map(\.name), ["x.mp3"])
    }
}
