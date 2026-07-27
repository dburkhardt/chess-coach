import XCTest

final class ChessCoachUITests: XCTestCase {
    @MainActor
    func testLaunchesIntoOnboardingOrNewGame() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Welcome to Chess Coach"].waitForExistence(timeout: 3)
                || app.staticTexts["New Game"].waitForExistence(timeout: 3)
        )
    }
}
