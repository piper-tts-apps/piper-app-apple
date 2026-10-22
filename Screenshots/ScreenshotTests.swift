import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false

        setupSnapshot(app)
        app.launch()
#if os(macOS)
        // On macOS, launch() alone can leave the app in the background with
        // no key window, and the test then finds no window to interact with
        // until somebody activates the app by hand (e.g. clicking its Dock
        // icon). Activate it the way that Dock click does, then wait until
        // a window actually exists before taking or tapping anything.
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
#endif
    }

    func testScreenshots() {
        snapshot("01_Main")
        app.buttons["gearshape"].tapOrClick()
        snapshot("02_Settings")
        goBack()
        app.buttons["questionmark.circle"].tapOrClick()
        snapshot("03_Help")
        goBack()
        scrollDown()
        snapshot("04_Voices")

    }
    
    private func goBack() {
#if os(iOS)
        let backButtonId = "BackButton"
#elseif os(macOS)
        let backButtonId = "chevron.backward"
#endif
        app.buttons[backButtonId].tapOrClick()
    }
    
    private func scrollDown() {
#if os(iOS)
        app.swipeUp(velocity: .fast)
#elseif os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0.0, deltaY: -200.0)
#endif
    }
}

extension XCUIElement {
    // Named tapOrClick rather than activate so it cannot collide with
    // XCUIApplication.activate(), which setUp uses on macOS.
    fileprivate func tapOrClick() {
#if os(iOS)
    tap()
#elseif os(macOS)
    click()
#endif
    }
}
