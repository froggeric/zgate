//
//  ModelProxyUITestsLaunchTests.swift
//  ModelProxyUITests
//
//  Created by Norvyn Zhang on 6/3/2026.
//

import XCTest

final class ModelProxyUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    // Shared app-under-test. Splash supervision must stay off for any launch
    // of it: every `xcodebuild test` here already runs a hosted ZGate and this
    // machine cannot run two splash instances (SplashManager.shouldSupervise).
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["ZGATE_DISABLE_SPLASH_SUPERVISION"] = "1"
    }
}
