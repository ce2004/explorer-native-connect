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
        XCTAssertTrue(element(app, "label CONTAINS %@", "Read-only").exists)
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
        app.buttons["Done"].tap()

        // Paused, so the new pick loads straight away rather than waiting behind the playing track.
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()

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
}
