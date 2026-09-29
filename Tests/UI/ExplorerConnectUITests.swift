import XCTest

/// Drives the app against Tests/Server/fake_server.py on 127.0.0.1:47810 (CI starts it).
@MainActor
final class ExplorerConnectUITests: XCTestCase {
    private let serverArgs = ["-host", "127.0.0.1", "-code", "12345678"]

    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-uitest-reset"] : []) + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    private func button(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit { issue in
            let text = issue.compactDescription.lowercased()
            // File names ("notes.txt") are what they are; the audit calls them not human-readable.
            let ignorable = text.contains("nearly") || text.contains("partially") || text.contains("human-readable")
                || issue.auditType == .contrast
            print("AUDIT \(screen) \(ignorable ? "ignored" : "FAIL"): \(issue.compactDescription) | \(issue.detailedDescription) | \(issue.element?.debugDescription ?? "no element")")
            return ignorable
        }
        print("OK audit \(screen)")
    }

    private func openTestDrive(_ app: XCUIApplication) {
        let drive = button(app, startingWith: "Test, T:")
        XCTAssertTrue(drive.waitForExistence(timeout: 30), "drive row")
        drive.tap()
        XCTAssertTrue(app.buttons["Docs, folder"].waitForExistence(timeout: 20), "folder listing")
    }

    private func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        field.typeText(text)
    }

    /// Lists are lazy: a row far down only exists once it's scrolled to.
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ e: XCUIElement, swipes: Int = 10) -> Bool {
        for _ in 0..<swipes {
            if e.waitForExistence(timeout: 1) && e.isHittable { return true }
            app.swipeUp()
        }
        return e.exists
    }

    private func longPress(_ e: XCUIElement) {
        XCTAssertTrue(e.waitForExistence(timeout: 15), e.debugDescription)
        e.press(forDuration: 1.2)
    }

    // MARK: Setup

    func testSetupRejectsWrongCodeThenConnects() throws {
        let app = launch()
        let computer = app.textFields["computer"]
        XCTAssertTrue(computer.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Connect"].exists)
        try audit(app, "setup")

        clearAndType(computer, "127.0.0.1")
        clearAndType(app.textFields["code"], "11111111")
        app.buttons["Connect"].tap()
        XCTAssertTrue(element(app, "label == %@", "Wrong pairing code.").waitForExistence(timeout: 15))

        clearAndType(app.textFields["code"], "12345678")
        app.buttons["Connect"].tap()
        XCTAssertTrue(button(app, startingWith: "Test, T:").waitForExistence(timeout: 30), "drives after connecting")
        print("OK setup")
    }

    // MARK: Browsing and file actions

    func testDrivesFoldersAndFileActions() throws {
        let app = launch(serverArgs)
        let drive = button(app, startingWith: "Test, T:")
        XCTAssertTrue(drive.waitForExistence(timeout: 30))
        XCTAssertTrue(drive.label.contains("free of"), drive.label)
        XCTAssertTrue(app.buttons["Google Drive, G:, unlimited space"].exists)
        XCTAssertTrue(app.buttons["Transfers"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        try audit(app, "drives")

        openTestDrive(app)
        XCTAssertTrue(app.buttons["notes, 1.2 KB, TXT"].exists)
        XCTAssertTrue(element(app, "label CONTAINS %@", "free of").exists, "drive space on the drive screen")
        try audit(app, "folder")

        // New folder
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        app.buttons["Folder actions"].tap()
        app.buttons["New folder"].tap()
        let nameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.typeText("UI \(stamp)")
        app.alerts.buttons["Create"].tap()
        let made = app.buttons["UI \(stamp), folder"]
        XCTAssertTrue(made.waitForExistence(timeout: 15), "new folder row")

        // Rename from the row's menu
        longPress(made)
        app.buttons["Rename"].tap()
        let renameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 10))
        clearAndType(renameField, "Renamed \(stamp)")
        app.alerts.buttons["Rename"].tap()
        let renamed = app.buttons["Renamed \(stamp), folder"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 15), "renamed row")

        // Copy notes.txt into it with the destination browser
        longPress(app.buttons["notes, 1.2 KB, TXT"])
        app.buttons["Copy to"].tap()
        let target = app.buttons["Renamed \(stamp)"]
        XCTAssertTrue(target.waitForExistence(timeout: 20), "destination folder in the picker")
        try audit(app, "destination picker")
        target.tap()
        let copyHere = app.buttons["Copy here"]
        XCTAssertTrue(copyHere.waitForExistence(timeout: 15))
        XCTAssertTrue(copyHere.isEnabled)
        copyHere.tap()

        // Get size says how big it is, and the row shows it
        let sized = app.buttons["Renamed \(stamp), folder, 1.2 KB"]
        let anyRenamed = button(app, startingWith: "Renamed \(stamp), folder")
        let deadline = Date().addingTimeInterval(25)
        while !sized.exists && Date() < deadline {
            longPress(anyRenamed)
            app.buttons["Get size"].tap()
            _ = sized.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(sized.exists, "folder size after copying into it")

        // Details
        longPress(app.buttons["notes, 1.2 KB, TXT"])
        app.buttons["Details"].tap()
        XCTAssertTrue(element(app, "label CONTAINS %@", "notes.txt").waitForExistence(timeout: 15))
        XCTAssertTrue(scrollTo(app, element(app, "label BEGINSWITH %@", "Read-only")), "read-only row")
        try audit(app, "details")
        app.buttons["Done"].tap()

        // Multi-select and delete
        app.buttons["Folder actions"].tap()
        app.buttons["Select"].tap()
        let selectable = button(app, startingWith: "Renamed \(stamp), folder")
        XCTAssertTrue(selectable.waitForExistence(timeout: 10))
        selectable.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        try audit(app, "selecting")
        app.buttons["Delete"].firstMatch.tap()
        var confirm = app.sheets.buttons["Delete"]
        if !confirm.waitForExistence(timeout: 5) {
            confirm = app.buttons.matching(identifier: "Delete").element(boundBy: 1)
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitGone(button(app, startingWith: "Renamed \(stamp)")), "deleted folder is gone")
        print("OK file actions")
    }

    // MARK: Details, ping

    func testDetailsReadEverythingAndPlayAChapter() throws {
        let app = launch(serverArgs)
        openTestDrive(app)
        app.buttons["Music, folder"].tap()
        let flac = app.buttons["tone, 170 KB, FLAC"]
        longPress(flac)
        app.buttons["Details"].tap()
        XCTAssertTrue(element(app, "label == %@", "Name, tone.flac").waitForExistence(timeout: 15), "each row is one element")
        XCTAssertTrue(app.buttons["Copy all details"].exists)
        try audit(app, "details top")
        app.buttons["Copy all details"].tap()

        // SHA-256 on request
        let hash = app.buttons["Compute SHA-256"]
        XCTAssertTrue(hash.exists)
        hash.tap()
        XCTAssertTrue(waitGone(app.buttons["Compute SHA-256"], timeout: 20), "not offered again once it's there")
        XCTAssertTrue(scrollTo(app, element(app, "label BEGINSWITH %@", "SHA-256, ")), "the hash row")

        XCTAssertTrue(scrollTo(app, element(app, "label == %@", "Duration, 20 seconds")), "durations are spoken in words")
        XCTAssertTrue(scrollTo(app, element(app, "label == %@", "Sample rate, 44.1 kHz")))
        XCTAssertTrue(scrollTo(app, element(app, "label == %@", "Channels, Stereo")))
        XCTAssertTrue(scrollTo(app, element(app, "label == %@", "Bit depth, 16-bit")))
        XCTAssertTrue(scrollTo(app, element(app, "label == %@", "Track, 1 of 2")), "tags")
        XCTAssertTrue(scrollTo(app, app.buttons["Chapter 2, Middle, starts at 10 seconds"]), "chapters are buttons")
        try audit(app, "details bottom")
        app.buttons["Done"].tap()

        // A chapter plays from where it starts (a two-minute file, so the test isn't racing the end of the track).
        longPress(app.buttons["long, 1.8 MB, WAV"])
        app.buttons["Details"].tap()
        let chapter = app.buttons["Chapter 2, Middle, starts at 1 minute"]
        XCTAssertTrue(scrollTo(app, chapter), "chapter row")
        chapter.tap()
        app.buttons["Done"].tap()
        let bar = button(app, startingWith: "Now playing, long")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the chapter plays")
        bar.tap()
        let position = element(app, "label == %@", "Position")
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let end = Date().addingTimeInterval(20)
        var v = ""
        while Date() < end {
            v = (position.value as? String) ?? ""
            if v.hasPrefix("1 minute") { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(v.hasPrefix("1 minute"), "started from the chapter: \(v)")
        print("OK details")
    }

    func testTestConnectionSaysThePing() throws {
        let app = launch(serverArgs)
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let test = app.buttons["Test connection"]
        XCTAssertTrue(test.waitForExistence(timeout: 10))
        test.tap()
        let report = element(app, "label BEGINSWITH %@", "Connected to Fake laptop. Ping ")
        XCTAssertTrue(report.waitForExistence(timeout: 20))
        XCTAssertTrue(report.label.contains("(lowest "), report.label)
        XCTAssertTrue(report.label.hasSuffix("Direct connection."), report.label)
        try audit(app, "settings")
        XCTAssertTrue(scrollTo(app, app.buttons["Clear cache"]), "the cache can be cleared")
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Cache size").exists)
        app.buttons["Clear cache"].tap()
        print("OK ping")
    }

    // MARK: Equalizer

    func testEqualizerScreen() throws {
        let app = launch(serverArgs)
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let link = button(app, startingWith: "Equalizer")
        XCTAssertTrue(scrollTo(app, link), "Equalizer in Settings")
        link.tap()
        let toggle = app.switches["Equalizer"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let band = element(app, "label == %@", "125 hertz")
        XCTAssertTrue(band.waitForExistence(timeout: 5), "each band is one element")
        XCTAssertEqual(band.value as? String, "0 decibels")
        XCTAssertTrue(element(app, "label == %@", "16 kilohertz").exists || scrollTo(app, element(app, "label == %@", "16 kilohertz")))
        app.swipeDown()
        try audit(app, "equalizer")

        // Switch it on: the switch control itself (tapping the row's label does nothing on iOS).
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        knob.tap()
        if !waitForValue(toggle, "1", timeout: 3) { knob.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap() }
        XCTAssertTrue(waitForValue(toggle, "1"), "switched on")

        // Typed: from the band's menu (a VoiceOver action too).
        longPress(band)
        app.buttons["Type a value"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        clearAndType(field, "5")
        app.alerts.buttons["Set"].tap()
        XCTAssertTrue(waitForValue(band, "plus 5 decibels"), "typed value: \(band.value ?? "")")


        let reset = app.buttons["Reset all"]
        XCTAssertTrue(scrollTo(app, reset))
        reset.tap()
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        XCTAssertEqual(band.value as? String, "0 decibels", "Reset all")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let back = button(app, startingWith: "Equalizer")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.label.contains("On") || (back.value as? String) == "On", "Settings says it's on: \(back.label)")
        print("OK equalizer")
    }

    // MARK: Playback

    func testPlaysFlacDecodedAudioAndSkipsBrokenFiles() throws {
        let app = launch(serverArgs)
        openTestDrive(app)
        app.buttons["Music, folder"].tap()
        let flac = app.buttons["tone, 170 KB, FLAC"]
        XCTAssertTrue(flac.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["clip, 900 bytes, MP4"].exists, "videos are listed as audio")
        try audit(app, "music folder")

        flac.tap()
        let bar = button(app, startingWith: "Now playing")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        bar.tap()
        let position = app.otherElements["Position"].exists ? app.otherElements["Position"] : element(app, "label == %@", "Position")
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(position, notEqualTo: "0 seconds", timeout: 20), "FLAC position moves")
        try audit(app, "now playing")
        XCTAssertTrue(scrollTo(app, button(app, startingWith: "EQ")), "the EQ is reachable from Now Playing")
        app.buttons["Done"].tap()

        // Paused, so the new pick loads straight away rather than waiting behind the playing track.
        // (The 20-second tone may already have finished on a slow simulator; then it's stopped anyway.)
        let pause = app.buttons["Pause"]
        if pause.waitForExistence(timeout: 5) { pause.tap() }

        // A file that won't decode is announced and skipped to the next one.
        app.buttons["a broken, 5 KB, OGG"].tap()
        let next = element(app, "label BEGINSWITH %@", "Now playing, b real")
        XCTAssertTrue(next.waitForExistence(timeout: 30), "skipped to the decoded Opus file")
        button(app, startingWith: "Now playing").tap()
        let position2 = element(app, "label == %@", "Position")
        XCTAssertTrue(position2.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(position2, notEqualTo: "0 seconds", timeout: 20), "decoded audio plays")
        print("OK playback")
    }

    private func waitForValue(_ e: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (e.value as? String) == value { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func waitForValue(_ e: XCUIElement, notEqualTo value: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = e.value as? String, !v.isEmpty, v != value, !v.hasPrefix("0 seconds") { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func testResumesPlaybackAfterRelaunch() throws {
        var app = launch(serverArgs)
        openTestDrive(app)
        app.buttons["Music, folder"].tap()
        let flac = app.buttons["tone, 170 KB, FLAC"]
        XCTAssertTrue(flac.waitForExistence(timeout: 20))
        flac.tap()
        button(app, startingWith: "Now playing").tap()
        let position = element(app, "label == %@", "Position")
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            if let v = position.value as? String, v.hasPrefix("6 ") || v.hasPrefix("7 ") || v.hasPrefix("8 ") { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app = launch(serverArgs, reset: false)
        let bar = button(app, startingWith: "Now playing")
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "the track is back after relaunch")
        bar.tap()
        let restored = element(app, "label == %@", "Position")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(restored, notEqualTo: "0 seconds", timeout: 20))
        let v = (restored.value as? String) ?? ""
        XCTAssertFalse(v.hasPrefix("1 second") || v.hasPrefix("2 seconds"), "picked up where it was, not from the start: \(v)")
        XCTAssertTrue(app.buttons["Pause"].exists, "it was playing, so it plays again")
        print("OK resume playback")
    }

    // MARK: Offline

    func testOfflineShowsSavedLists() throws {
        var app = launch(serverArgs)
        openTestDrive(app)
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()

        app = launch(serverArgs + ["-port", "47899"], reset: false)
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Offline, showing saved list").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "label CONTAINS %@", "isn't answering").exists, "says why")
        XCTAssertTrue(app.buttons["Try again"].exists)
        let drive = button(app, startingWith: "Test, T:")
        XCTAssertTrue(drive.exists, "saved drive list")
        try audit(app, "offline drives")
        drive.tap()
        XCTAssertTrue(app.buttons["Docs, folder"].waitForExistence(timeout: 30), "saved folder list")
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Offline, showing saved list").exists)
        XCTAssertFalse(app.buttons["Folder actions"].exists, "no changes while offline")
        print("OK offline")
    }

    // MARK: Clipboard

    /// Talks to the fake server directly, playing the part of someone at the laptop.
    @discardableResult
    private func server(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:47810" + path)!)
        request.httpMethod = method
        request.setValue("12345678", forHTTPHeaderField: "X-Connect-Code")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func testClipboardBothWays() throws {
        let app = launch(serverArgs)
        // Copy on PC from a file row
        openTestDrive(app)
        longPress(app.buttons["notes, 1.2 KB, TXT"])
        app.buttons["Copy on PC"].tap()
        var copied = false
        for _ in 0..<20 where !copied {
            copied = ((server("GET", "/api/clipboard")["files"] as? [String]) ?? []).contains("T:\\notes.txt")
            if !copied { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(copied, "Copy on PC put the file on the laptop's clipboard")

        let tab = app.tabBars.buttons["Clipboard"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.buttons["notes, TXT"].waitForExistence(timeout: 15), "copied files are listed")

        // Live update from the laptop
        let words = "Hello from the PC \(Int.random(in: 100...999))"
        server("POST", "/api/clipboard", ["text": words])
        let shown = app.staticTexts["pc clipboard text"]
        XCTAssertTrue(shown.waitForExistence(timeout: 35))
        XCTAssertEqual(shown.label, words)
        XCTAssertTrue(app.buttons["Copy to iPhone"].exists)
        app.buttons["Copy to iPhone"].tap()
        try audit(app, "clipboard")

        // Typed on the phone, sent to the laptop
        let field = app.textFields["text to send"].exists ? app.textFields["text to send"] : app.textViews["text to send"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Typed on the phone")
        app.buttons["Send text"].tap()
        var sent = false
        for _ in 0..<20 where !sent {
            sent = (server("GET", "/api/clipboard")["text"] as? String) == "Typed on the phone"
            if !sent { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(sent, "the laptop's clipboard got the typed text")

        // Files copied on the laptop
        server("POST", "/api/clipboard/files", ["paths": ["T:\\Music\\tone.flac", "T:\\notes.txt"]])
        XCTAssertTrue(app.buttons["tone, FLAC"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.buttons["Save all to iPhone"].exists)

        // History
        // The button is at the end of a lazy list, so it only exists once scrolled to.
        let clear = app.buttons["Clear history"]
        for _ in 0..<8 where !clear.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        var confirm = app.sheets.buttons["Clear history"]
        if !confirm.waitForExistence(timeout: 5) {
            confirm = app.buttons.matching(identifier: "Clear history").element(boundBy: 1)
        }
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No history yet."].waitForExistence(timeout: 10))
        print("OK clipboard")
    }

    // MARK: Transfers

    func testSaveToIPhone() throws {
        let app = launch(serverArgs)
        openTestDrive(app)
        longPress(app.buttons["notes, 1.2 KB, TXT"])
        app.buttons["Save to iPhone"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let transfers = app.buttons["Transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 10))
        transfers.tap()
        XCTAssertTrue(element(app, "label == %@", "notes.txt, saved to iPhone").waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Open"].exists)
        XCTAssertTrue(app.buttons["Save to Files"].exists)
        try audit(app, "transfers")
        print("OK save to iPhone")
    }

    func testStopAllTransfers() throws {
        // Small chunks, and slow.bin is served slowly, so the download is still going when we stop it.
        let app = launch(serverArgs + ["-chunk", "65536"])
        openTestDrive(app)
        app.buttons["Docs, folder"].tap()
        longPress(app.buttons["slow, 3 MB, BIN"])
        app.buttons["Save to iPhone"].tap()
        // The activity bar under every screen opens Transfers, and has Stop all as a VoiceOver action.
        let bar = button(app, startingWith: "Transfers, ")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "activity bar")
        bar.tap()
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "slow.bin, saving to iPhone").waitForExistence(timeout: 15), "under way")
        let stop = app.buttons["Stop all transfers"]
        XCTAssertTrue(stop.exists)
        XCTAssertTrue(app.buttons["Transfers menu"].exists)
        try audit(app, "transfers running")
        stop.tap()
        XCTAssertTrue(element(app, "label == %@", "slow.bin, cancelled").waitForExistence(timeout: 5), "stopped at once")
        XCTAssertTrue(waitGone(app.buttons["Stop all transfers"], timeout: 5), "nothing left to stop")
        print("OK stop all")
    }
}

private final class ResultBox: @unchecked Sendable {
    var data: Data?
}
