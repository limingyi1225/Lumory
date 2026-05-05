import XCTest

final class iPadAdaptiveModalSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThemeFilteredEntriesOpensAsAdaptiveModal() throws {
        let app = launchSeededApp()
        openInsights(app)

        firstThemeCard(in: app).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["themeFilteredEntriesContent"].waitForExistence(timeout: 5),
            "Theme filtered entries did not open"
        )
    }

    @MainActor
    func testThemeMergeSheetOpensFromFilteredEntries() throws {
        let app = launchSeededApp()
        openInsights(app)

        firstThemeCard(in: app).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["themeFilteredEntriesContent"].waitForExistence(timeout: 5),
            "Theme filtered entries did not open"
        )

        app.buttons["更多操作"].tap()
        let merge = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "合并到其他主题")
        ).firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 3), "Merge menu action did not appear")
        merge.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["themeMergeScrollView"].waitForExistence(timeout: 5),
            "Theme merge sheet did not open"
        )
    }

    @MainActor
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-LumoryUITestSampleData", "YES",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launchEnvironment = [
            "LUMORY_UI_TEST": "1"
        ]
        app.launch()
        waitForHome(app)
        return app
    }

    @MainActor
    private func waitForHome(_ app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(
            app.buttons["设置"].waitForExistence(timeout: timeout),
            "Home did not finish loading"
        )
        usleep(800_000)
    }

    @MainActor
    private func openInsights(_ app: XCUIApplication) {
        let insightsButton = app.buttons["洞察"]
        XCTAssertTrue(insightsButton.waitForExistence(timeout: 5), "Insights button missing")
        insightsButton.tap()
        XCTAssertTrue(app.navigationBars["洞察"].waitForExistence(timeout: 5), "Insights did not open")
        usleep(2_000_000)
    }

    @MainActor
    private func firstThemeCard(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "主题 ")
        let cards = app.buttons.matching(predicate)
        for _ in 0..<5 {
            let first = cards.firstMatch
            if first.waitForExistence(timeout: 1), first.isHittable {
                return first
            }
            app.scrollViews.firstMatch.swipeUp()
            usleep(500_000)
        }
        XCTFail("No hittable theme card found")
        return cards.firstMatch
    }

}
