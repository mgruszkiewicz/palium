//
//  paliumUITests.swift
//  paliumUITests
//
//  Created by Mateusz Gruszkiewicz on 12/03/2026.
//

import XCTest

final class paliumUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Update Available

    @MainActor
    func testUpdateAvailableShowsCorrectUI() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-phase", "needsUpdate",
            "--ui-test-cdn-version", "0.201.0",
            "--ui-test-local-version", "0.200.0"
        ]
        app.launch()

        // Title and version subtitle should be visible
        XCTAssertTrue(app.staticTexts["Palium"].exists)
        XCTAssertTrue(app.staticTexts["Palia v0.201.0"].exists)

        // Update-specific elements
        XCTAssertTrue(app.staticTexts["Update Available"].exists)
        XCTAssertTrue(app.staticTexts["v0.200.0 → v0.201.0"].exists)

        // Both action buttons should be present
        XCTAssertTrue(app.buttons["Update Game"].exists)
        XCTAssertTrue(app.buttons["Launch Anyway"].exists)
    }

    @MainActor
    func testUpdateAvailableWithCustomVersions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-phase", "needsUpdate",
            "--ui-test-cdn-version", "1.0.0",
            "--ui-test-local-version", "0.999.0"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Palia v1.0.0"].exists)
        XCTAssertTrue(app.staticTexts["v0.999.0 → v1.0.0"].exists)
    }

    // MARK: - Ready State

    @MainActor
    func testReadyStateShowsLaunchButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-phase", "ready"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Ready to Play"].exists)
        XCTAssertTrue(app.buttons["Launch Game"].exists)
        XCTAssertTrue(app.buttons["Verify & Repair Files"].exists)

        // Update elements should NOT be visible
        XCTAssertFalse(app.staticTexts["Update Available"].exists)
        XCTAssertFalse(app.buttons["Update Game"].exists)
    }

    // MARK: - Download State

    @MainActor
    func testNeedsDownloadShowsDownloadButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-phase", "needsDownload"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Download Palia"].exists)
        XCTAssertTrue(app.buttons["Download"].exists)

        // Update and ready elements should NOT be visible
        XCTAssertFalse(app.staticTexts["Update Available"].exists)
        XCTAssertFalse(app.staticTexts["Ready to Play"].exists)
    }

    // MARK: - Performance

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
