import XCTest

/// The photo viewer keeps a photo centred however its bars come and go. LazyPager reads the safe area
/// only when a swipe settles, so bars that changed the pager's safe area left the photo 54 pt off.
final class PhotoViewerTests: XCTestCase {
    @MainActor func testPhotoStaysCentred() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-demoOpenPhoto", "YES"]
        app.launch()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the viewer never opened")
        assertCentred(app, "opened")

        app.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a tap didn't hide the bars")
        app.swipeLeft()
        assertCentred(app, "swiped with the bars hidden")
        app.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "a tap didn't bring the bars back")
        assertCentred(app, "bars shown again")

        // A short, slow drag down springs back instead of closing.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 20)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        assertCentred(app, "short drag")
    }

    /// The on-screen photo's middle sits on the screen's middle, once things settle.
    @MainActor private func assertCentred(_ app: XCUIApplication, _ step: String, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        var offset: CGFloat?
        for _ in 0..<20 {
            let onScreen = app.images.matching(identifier: "viewer.photo").allElementsBoundByIndex
                .map(\.frame).first { abs($0.midX - screen.midX) < 1 }
            offset = onScreen.map { $0.midY - screen.midY }
            if let offset, abs(offset) < 1 { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("\(step): photo is \(offset.map { "\($0) pt off centre" } ?? "not on screen")", line: line)
    }
}
