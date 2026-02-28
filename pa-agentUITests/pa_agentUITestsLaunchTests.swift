//
//  pa_agentUITestsLaunchTests.swift
//  pa-agentUITests
//
//  Created by ZHEN YUAN on 12/2/2026.
//

import XCTest

final class pa_agentUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-PERMISSION_SETUP_SHOWN", "YES"]

        addUIInterruptionMonitor(withDescription: "System Permission Alerts") { alert in
            let preferredButtons = [
                "Allow",
                "Allow While Using App",
                "OK",
                "Continue",
                "Don’t Allow",
                "Don't Allow"
            ]

            for title in preferredButtons {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app.launch()
        app.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App failed to reach foreground state.")

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
