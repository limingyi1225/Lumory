//
//  ScreenshotTests.swift
//  ChronoteUITests
//
//  自动化生成 App Store Connect 用的 iPhone 截图。
//
//  运行方式:走 `Scripts/generate-screenshots.sh` —— 它会先 boot 模拟器、override 状态栏
//  (9:41 / 满电 / 满信号),再调 `xcodebuild test -only-testing` 跑这个文件,
//  最后把 .xcresult 里的 PNG 提取到 `Screenshots/zh-Hans/`。
//
//  也可以单独从 Xcode IDE 里跑(注意状态栏不会自动覆盖,会带"测试中"的红条)。
//
//  每个 test 方法独立启动 app,通过 launchArgs `-LumoryUITestSampleData YES` 触发
//  `UITestSampleData.seedIfNeeded()` 擦库 + 种入 30 条样例日记(主角"林子衿")。
//
//  截图通过 `XCTAttachment(screenshot:) + lifetime = .keepAlways` 写入 .xcresult bundle,
//  名字带前缀(01-Home / 02-Insights ...)以便排序。

import XCTest

final class ScreenshotTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 启动 app,带样例数据 flag + 中文 locale。
    /// 每个 test 都调用一次,保证截图互不影响。
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            // 触发 UITestSampleData.seedIfNeeded
            "-LumoryUITestSampleData", "YES",
            // 强制中文 UI(覆盖 simulator 默认 locale)
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            // 关掉系统动画里的弹簧 overshoot,截图更稳(可选)
            // "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launchEnvironment = [
            "LUMORY_UI_TEST": "1"
        ]
        app.launch()
        return app
    }

    /// 写一张截图到 .xcresult。命名 `NN-Page.png` 以便排序。
    @MainActor
    private func snapshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 等到 SplashView 淡出 + Home 主界面就位 —— 顶栏的"设置"按钮出现即可。
    @MainActor
    private func waitForHome(_ app: XCUIApplication, timeout: TimeInterval = 8) {
        let settingsButton = app.buttons["设置"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: timeout),
            "等不到 Home 主界面 (设置按钮 8s 内未出现)"
        )
        // Splash 的 0.8s 淡出动画走完,再让 SwiftUI 跑一帧把 entries 渲出来
        usleep(800_000)
    }

    // MARK: - Screenshots

    /// 01 — Home:输入卡 + 心情条 + 最近日记列表
    @MainActor
    func test_01_Home() throws {
        let app = launchApp()
        waitForHome(app)
        snapshot(app, named: "01-Home")
    }

    /// 02 — Insights 主入口:心情曲线 + 主题卡 + 月历
    @MainActor
    func test_02_Insights() throws {
        let app = launchApp()
        waitForHome(app)

        let insightsButton = app.buttons["洞察"]
        XCTAssertTrue(insightsButton.waitForExistence(timeout: 5), "洞察按钮不见")
        insightsButton.tap()

        // 等 Insights 标题出现 + 让数据 fetch 完(InsightsEngine 走 background context)
        let title = app.navigationBars["洞察"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        usleep(2_000_000) // 2s — 给图表 / 主题卡的数据计算 + 入场动画留时间

        snapshot(app, named: "02-Insights")
    }

    /// 03 — Calendar:Insights 滚到月历位置(模块在心情曲线下面一块)
    /// 用精准 swipe(从下三分之一往上拖到中间)替代默认 swipeUp(默认是整屏 swipe,容易过位)
    @MainActor
    func test_03_Calendar() throws {
        let app = launchApp()
        waitForHome(app)

        app.buttons["洞察"].tap()
        XCTAssertTrue(app.navigationBars["洞察"].waitForExistence(timeout: 5))
        usleep(1_500_000)

        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            // 短距 swipe:从屏幕 75% 滑到 35%,刚好把 mood chart 顶出去 + 月历完整露出
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            usleep(800_000)
        }
        snapshot(app, named: "03-Calendar")
    }

    /// 04 — Themes:滚到主题卡 + correlation chips + heatmap 区域
    @MainActor
    func test_04_Themes() throws {
        let app = launchApp()
        waitForHome(app)

        app.buttons["洞察"].tap()
        XCTAssertTrue(app.navigationBars["洞察"].waitForExistence(timeout: 5))
        usleep(1_500_000)

        // 两次中等 swipe,精准走过 mood chart + calendar,落在主题卡顶部
        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            for _ in 0..<2 {
                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                start.press(forDuration: 0.05, thenDragTo: end)
                usleep(400_000)
            }
            usleep(600_000)
        }
        snapshot(app, named: "04-Themes")
    }

    /// 05 — Ask Past:点击 toolbar 的"回顾",截 AskPast 入口的 preset 提问
    @MainActor
    func test_05_AskPast() throws {
        let app = launchApp()
        waitForHome(app)

        app.buttons["洞察"].tap()
        XCTAssertTrue(app.navigationBars["洞察"].waitForExistence(timeout: 5))
        usleep(1_000_000)

        // toolbar 上的"与过去对话"按钮(accessibilityLabel)
        let askPast = app.buttons["与过去对话"]
        XCTAssertTrue(askPast.waitForExistence(timeout: 5), "AskPast 入口找不到")
        askPast.tap()

        // 等 sheet + preset 加载完成。preset 是 AI 生成,有缓存就秒出,无缓存可能要 5-10s。
        // 我们给 6s 然后无论如何都截 —— 即便还在 loading,玻璃骨架也是有内容的。
        usleep(6_000_000)
        snapshot(app, named: "05-AskPast")
    }

    /// 06 — Diary 详情:从首页点一条日记进 detail view
    ///
    /// SwiftUI List 里 timelineRow 的 `Button(.plain)` 在 a11y tree 里可能是 button
    /// 也可能被 List 裹成 cell;两条都试,谁先拿到用谁。
    /// 目标日记选 #10 "半马试跑 1:43:20"(mood 0.85,图标 + 情绪色最突出)。
    @MainActor
    func test_06_DiaryDetail() throws {
        let app = launchApp()
        waitForHome(app)

        // 稍微往下滚一点,让"半马"那条从第 3 屏位置到屏幕可见区
        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            usleep(500_000)
        }

        // 用 summary 的关键词匹配 —— "半马"是 entry #10 的 summary 里的独特词
        let predicate = NSPredicate(format: "label CONTAINS '半马' OR label CONTAINS '九溪 18K'")
        let candidates = app.descendants(matching: .any).matching(predicate)
        let target: XCUIElement
        if candidates.count > 0 {
            // 优先找 hittable 的(避免点到屏幕外的 label)
            var picked: XCUIElement? = nil
            for i in 0..<min(candidates.count, 10) {
                let el = candidates.element(boundBy: i)
                if el.exists && el.isHittable {
                    picked = el
                    break
                }
            }
            target = picked ?? candidates.firstMatch
        } else {
            // fallback:第一条 cell
            target = app.cells.firstMatch
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "找不到任何日记行")
        target.tap()

        // detail 入场动画 + 图片加载
        usleep(1_800_000)
        snapshot(app, named: "06-DiaryDetail")
    }
}
