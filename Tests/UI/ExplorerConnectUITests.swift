import XCTest

@MainActor
final class ExplorerConnectUITests: XCTestCase {
    func testSetupScreenIsAccessible() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.textFields["computer"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields["code"].exists)
        XCTAssertTrue(app.buttons["Connect"].exists)
        try audit(app, "setup")
    }

    func testBrowsingDemoData() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let music = app.buttons["Music, G:"]
        XCTAssertTrue(music.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Local disk, C:"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        try audit(app, "drives")
        music.tap()
        XCTAssertTrue(app.buttons["Albums, folder"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["notes, 1.2 KB, TXT"].exists)
        XCTAssertTrue(app.buttons["Song, 4.2 MB, FLAC"].exists)
        try audit(app, "folder")
        print("OK browsing demo data")
    }

    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit { issue in
            let text = issue.compactDescription.lowercased()
            let ignorable = text.contains("nearly") || text.contains("partially") || issue.auditType == .contrast
            print("AUDIT \(screen) \(ignorable ? "ignored" : "FAIL"): \(issue.compactDescription) | \(issue.detailedDescription) | \(issue.element?.debugDescription ?? "no element")")
            return ignorable
        }
        print("OK audit \(screen)")
    }
}
