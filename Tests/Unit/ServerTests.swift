import AVFoundation
import XCTest
@testable import ExplorerConnect

/// Runs against Tests/Server/fake_server.py on port 47810 (CI starts it). Skipped when it isn't running.
@MainActor
final class ServerTests: XCTestCase {
    let client = ConnectClient(host: "127.0.0.1", code: "12345678")

    override func setUp() async throws {
        do {
            _ = try await client.info(timeout: 2)
        } catch {
            throw XCTSkip("The fake server isn't running.")
        }
    }

    private func unique(_ base: String) -> String { "\(base) \(UUID().uuidString.prefix(6))" }

    private func waitFor(_ what: String, timeout: TimeInterval = 30, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testInfoFormatsDrivesAndLists() async throws {
        let info = try await client.info()
        XCTAssertEqual(info.apiVersion, 2)
        let formats = try await client.formats()
        XCTAssertTrue(formats.needsDecoding("x.opus"))
        XCTAssertFalse(formats.needsDecoding("x.flac"))
        let drives = try await client.drives()
        let t = try XCTUnwrap(drives.first { $0.letter == "T:" })
        XCTAssertGreaterThan(t.size, 0)
        XCTAssertTrue(Labels.drive(t).contains("free of"))
        XCTAssertTrue(drives.contains { $0.unlimited })
        let root = try await client.list("T:\\")
        XCTAssertTrue(root.contains { $0.name == "Music" && $0.folder })
        let docs = try await client.list("T:\\Docs")
        let weird = try XCTUnwrap(docs.first { $0.name.hasPrefix("weird") })
        XCTAssertEqual(weird.name, "weird +&#% 日本.txt", "names with + & # % and non-ASCII survive the round trip")
        print("OK server list")
    }

    func testRangeOnAWeirdName() async throws {
        var request = client.request(try XCTUnwrap(client.fileURL("T:\\Docs\\weird +&#% 日本.txt")))
        request.setValue("bytes=0-2", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "odd")
    }

    func testErrorsAreToldApart() async throws {
        do {
            _ = try await ConnectClient(host: "127.0.0.1", code: "00000000").drives()
            XCTFail("wrong code accepted")
        } catch {
            XCTAssertEqual(error as? ConnectError, .wrongCode)
        }
        do {
            _ = try await client.list("G:\\")
            XCTFail("unmounted Drive listed")
        } catch {
            XCTAssertEqual(error as? ConnectError, .driveNotMounted("Google Drive isn't mounted."))
        }
        do {
            _ = try await client.list("T:\\No such folder")
            XCTFail("missing folder listed")
        } catch {
            guard case .notFound = error as? ConnectError else { return XCTFail("\(error)") }
        }
        do {
            _ = try await ConnectClient(host: "127.0.0.1", code: "12345678", port: 47899).info()
            XCTFail("closed port answered")
        } catch {
            XCTAssertEqual(error as? ConnectError, .appNotRunning("127.0.0.1"))
            XCTAssertTrue(ConnectError.isConnectionProblem(error))
        }
        print("OK server errors")
    }

    func testFileActions() async throws {
        let name = unique("Unit folder")
        let made = try await client.mkdir(in: "T:\\", name: name)
        XCTAssertEqual(made, "T:\\\(name)")
        do {
            _ = try await client.mkdir(in: "T:\\", name: name)
            XCTFail("made the same folder twice")
        } catch {
            guard case .nameTaken = error as? ConnectError else { return XCTFail("\(error)") }
        }
        let renamed = try await client.rename(made, to: name + " renamed")
        XCTAssertEqual(renamed, "T:\\\(name) renamed")

        let job = try await client.copy(["T:\\notes.txt"], to: renamed, conflict: .rename, move: false)
        try await waitFor("the copy") { (try? await self.client.job(job))?.isRunning == false }
        let status = try await client.job(job)
        XCTAssertEqual(status.state, "done")
        XCTAssertEqual(status.itemsDone, 1)
        let inside = try await client.list(renamed)
        XCTAssertEqual(inside.map(\.name), ["notes.txt"])

        let size = try await client.size(renamed)
        XCTAssertEqual(size.bytes, 1229)
        XCTAssertEqual(size.files, 1)
        XCTAssertTrue(size.complete)

        let stat = try await client.stat("T:\\Music\\tone.flac")
        XCTAssertEqual(stat.tags?.title, "Test Tone")

        let deleted = try await client.delete([renamed, "T:\\gone \(UUID().uuidString)"])
        XCTAssertEqual(deleted.deleted, 1)
        XCTAssertEqual(deleted.failed.count, 1)
        print("OK server file actions")
    }

    // MARK: Transfers

    private func makeCenter(chunk: Int64) -> TransferCenter {
        let center = TransferCenter()
        center.clientProvider = { ConnectClient(host: "127.0.0.1", code: "12345678") }
        center.uploadChunkSize = chunk
        center.downloadChunkSize = chunk
        center.announceProgress = false
        return center
    }

    private func tempFile(_ name: String, bytes: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 997) { data[i] = UInt8(i % 251) }
        try data.write(to: url)
        return url
    }

    func testResumableUploadWithPauseAndResume() async throws {
        let center = makeCenter(chunk: 256 * 1024)
        let name = unique("upload") + ".bin"
        let file = try tempFile(name, bytes: 3 * 1024 * 1024 + 123)
        center.upload(files: [file], to: "T:\\Docs", conflict: .rename)
        let id = try XCTUnwrap(center.records.last?.id)
        try await waitFor("some bytes to go") { (center.record(id)?.done ?? 0) > 0 }
        center.pause(id)
        XCTAssertEqual(center.record(id)?.state, .paused)
        let pausedAt = center.record(id)?.done ?? 0
        try await Task.sleep(for: .milliseconds(500))
        center.resume(id)
        try await waitFor("the upload", timeout: 60) { center.record(id)?.state == .done }
        XCTAssertGreaterThan(pausedAt, 0)
        let listed = try await client.list("T:\\Docs")
        XCTAssertEqual(listed.first { $0.name == name }?.size, 3 * 1024 * 1024 + 123)
        print("OK resumable upload")
    }

    func testUploadToDriveShowsSecondPhase() async throws {
        let center = makeCenter(chunk: 1024 * 1024)
        let name = unique("drive") + ".bin"
        let file = try tempFile(name, bytes: 1500 * 1024)
        center.upload(files: [file], to: "T:\\Drive", conflict: .rename)
        let id = try XCTUnwrap(center.records.last?.id)
        var sawDrivePhase = false
        try await waitFor("the Drive upload", timeout: 60) {
            if center.record(id)?.state == .sendingToDrive { sawDrivePhase = true }
            return center.record(id)?.state == .done
        }
        XCTAssertTrue(sawDrivePhase, "the Google Drive phase was shown")
        let listed = try await client.list("T:\\Drive")
        XCTAssertTrue(listed.contains { $0.name == name })
        print("OK drive upload")
    }

    func testDownloadInChunksToDocuments() async throws {
        let center = makeCenter(chunk: 40 * 1024)
        center.download([(path: "T:\\Music\\tone.flac", name: "tone.flac", size: 173_742)])
        let id = try XCTUnwrap(center.records.last?.id)
        try await waitFor("the download", timeout: 90) { center.record(id)?.state == .done || center.record(id)?.state == .failed }
        let record = try XCTUnwrap(center.record(id))
        XCTAssertEqual(record.state, .done, record.message)
        let saved = try XCTUnwrap(center.savedURL(record))
        XCTAssertTrue(saved.path.hasPrefix(TransferCenter.documents.path), "saved where the Files app sees it")
        let local = try Data(contentsOf: saved)
        let (remote, _) = try await URLSession.shared.data(for: client.request(try XCTUnwrap(client.fileURL("T:\\Music\\tone.flac"))))
        XCTAssertEqual(local, remote)
        center.remove(id)
        try? FileManager.default.removeItem(at: saved)
        print("OK chunked download")
    }

    // MARK: Playback

    private func makePlayer() -> Player {
        let player = Player()
        player.persistEnabled = false
        player.probe = { true }
        return player
    }

    private func track(_ name: String) -> Player.Track {
        Player.Track(name: name, path: "T:\\Music\\\(name)", folder: "Music")
    }

    func testFlacPlaysAndSeeksInstantly() async throws {
        let player = makePlayer()
        player.play(tracks: [track("tone.flac")], client: client)
        try await waitFor("FLAC to play", timeout: 30) { player.isPlaying && player.position > 1 }
        XCTAssertEqual(player.duration, 20, accuracy: 0.5)
        player.seek(to: 12)
        XCTAssertEqual(player.position, 12, accuracy: 0.01, "the position jumps straight away")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(player.isPlaying, "playing carries on through a seek")
        XCTAssertGreaterThanOrEqual(player.position, 12)
        XCTAssertLessThan(player.position, 14)
        player.pause()
        print("OK flac playback and seek")
    }

    func testDecodedAudioPlaysAndSeeks() async throws {
        let player = makePlayer()
        player.formats = try await client.formats()
        player.play(tracks: [track("b real.opus")], client: client)
        try await waitFor("decoded audio to play", timeout: 30) { player.isPlaying && player.position > 0.5 }
        XCTAssertEqual(player.duration, 8, accuracy: 0.5, "the WAV from /api/audio has a known length")
        player.seek(to: 5)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.position, 5)
        player.pause()
        print("OK decoded audio")
    }

    func testBrokenFileIsSkipped() async throws {
        let player = makePlayer()
        player.formats = try await client.formats()
        player.keepPlayingUntilReady = false
        player.play(tracks: [track("a broken.ogg"), track("tone.flac")], client: client)
        try await waitFor("the next track after the broken one", timeout: 30) { player.index == 1 && player.isPlaying }
        XCTAssertEqual(player.current?.name, "tone.flac")
        player.pause()
        print("OK broken file skipped")
    }

    func testKeepsPlayingUntilTheNextTrackIsReady() async throws {
        let player = makePlayer()
        player.formats = try await client.formats()
        player.keepPlayingUntilReady = true
        let tracks = [track("tone.flac"), track("b real.opus")]
        player.play(tracks: tracks, client: client)
        try await waitFor("the first track", timeout: 30) { player.isPlaying && player.position > 1 }
        player.next()
        // Straight after asking, the old track is still the one playing, and still sounding.
        XCTAssertEqual(player.current?.name, "tone.flac")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.loadingTitle, "b real")
        try await waitFor("the switch", timeout: 30) { player.current?.name == "b real.opus" }
        XCTAssertNil(player.loadingTitle)
        try await waitFor("the new track to sound", timeout: 10) { player.isPlaying && player.position > 0.3 }

        // A track that can't load leaves the current one playing.
        player.play(tracks: [track("a broken.ogg")], client: client)
        try await waitFor("the failure", timeout: 30) { player.loadingTitle == nil }
        XCTAssertEqual(player.current?.name, "b real.opus")
        XCTAssertTrue(player.isPlaying)
        player.pause()
        print("OK keep playing until ready")
    }
}
