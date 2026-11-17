//
//  ModelProxyUITests.swift
//  ModelProxyUITests
//
//  Created by Norvyn Zhang on 6/3/2026.
//

import XCTest

final class ModelProxyUITests: XCTestCase {

    // Shared app-under-test. Splash supervision must stay off for any launch
    // of it: every `xcodebuild test` here already runs a hosted ZGate and this
    // machine cannot run two splash instances (SplashManager.shouldSupervise).
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
        app.launchEnvironment["ZGATE_DISABLE_SPLASH_SUPERVISION"] = "1"
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
}
