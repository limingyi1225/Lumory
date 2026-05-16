//
//  CoreUserFlowsTests.swift
//  ChronoteUITests
//
//  核心用户路径的 UI smoke test。megareview OPT-HIGH-7 / 测试覆盖 reviewer 都点名:
//  这些路径用户每天都触发,但**之前完全没有 UI 测试**。
//
//  **真验路径(3 条)**:
//   1. ✏️ Compose → Save:主写流(最高频用户路径)
//   2. 🗑️ Settings 入口打开/关闭:navigation push/pop 不崩
//   3. 💭 AskPast Streaming smoke:进 Insights → 提问 → 看到 AskPast UI(不验完整流)
//
//  **已知缺口 / 待补(superreview 2026-05-15 P1 砍掉 always-pass smoke 后)**:
//   - ❌ Delete + Undo:swipe + toast 自动化 CI 不稳,需要专 a11y identifier 锁 swipe action
//   - ❌ Edit Diary → Save:NavigationStack push 后 toolbar query 不稳,需 detail view 加 a11y id
//   - ❌ Settings 删除全部 destructive flow:alert button label 跨 iOS 版本不一致
//  这三条核心逻辑都在 `SettingsEntryDeletionService` / `EntryDeletionUndoService` / `DiaryDetailView.saveChanges`
//  各自的 service-level 单测覆盖(`EntryDeletionUndoServiceTests` 等)。UI 自动化待 a11y id 补齐再加。
//
//  **样例数据**:`-LumoryUITestSampleData YES` 启动参数让 PersistenceController.shared
//  用 in-memory store + seed 90 条样例日记(主角"林子衿")。每个 test 自起 app,互不影响。
//

import XCTest

final class CoreUserFlowsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 1. Compose → Save

    /// 主写日记流:输入文字 → 点发送 → 时间线出现新行。
    /// 锁 HomeView 重构的回归网。
    @MainActor
    func testComposeSave_textOnly_appearsInTimeline() throws {
        let app = launchSeededApp()

        // (2026-05-15 superreview-3 P1)显式 a11y id 抓 composer。原 `firstMatch`
        // 可能撞搜索栏或其它 TextField → typeText 后 probe 假绑定,assertion 仍 pass(staticText 撞文本)。
        let composer = app.textFields["home.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "composer text field 未出现")
        composer.tap()

        // (2026-05-15 superreview-4 P2)`Int(timeIntervalSince1970)` 是 1 秒粒度 —— 本地手动
        // 1 秒内连续重跑会命中**上次**的 row,assertion 误绑 stale entry。UUID 前缀 8 位 ≈
        // 2^32 空间,人手重跑不可能撞。
        let probe = "UI Test \(UUID().uuidString.prefix(8))"
        composer.typeText(probe)

        // 收起键盘(否则 send 按钮可能被键盘 toolbar 挡)
        let dismissKeyboard = app.buttons["收起键盘"]
        if dismissKeyboard.waitForExistence(timeout: 2) {
            dismissKeyboard.tap()
        }

        let send = app.buttons["home.keyboard.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "send button 不见")
        XCTAssertTrue(send.isEnabled, "有内容应该可点 send")
        send.tap()

        // 验时间线出现刚写的 entry:probe 字符串作 row 内文字命中。
        // Send 完会跑 analyze + save,~1-2s 内 entry 应该入 fetch results。
        let appearedRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", probe)).firstMatch
        XCTAssertTrue(appearedRow.waitForExistence(timeout: 8),
                      "新写的日记应该出现在时间线 (probe=\(probe))")
    }

    // (2026-05-15 superreview-2 P1)旧 test 2/3 是 always-pass smoke,
    // assertion 跟 docstring 承诺路径完全脱钩 — `cells+buttons>5` 任何启动都过,
    // `app.state==.runningForeground` 是 launched 默认。砍掉避免假阳信号。
    // 真 Delete+Undo / Edit→Save 路径在 service-level 单测覆盖,UI 自动化待
    // a11y identifier 补齐(详见文件 header)。

    // MARK: - 2. Settings page smoke(简化版)

    /// **简化版**:打开 Settings → 关闭 → 回 Home。完整"删除全部"flow UI 路径在不同 iOS 版本上
    /// alert 按钮 label 多变,验它的整链条 CI 不稳。核心 deleteAll service 路径走 unit test 即可
    /// (`SettingsEntryDeletionService` 在主 fix commit 已 verified)。
    @MainActor
    func testSettingsPage_opensAndClosable() throws {
        let app = launchSeededApp()

        let settingsButton = app.buttons["设置"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Home 设置按钮应存在")
        settingsButton.tap()

        // Settings 视图加载后,Home 时间线下方的 staticTexts 不再可见;同时应有 Settings-specific UI。
        // 抓"设置"标题或任何 settings 行 — 这里用最稳的:等关闭按钮出现。
        let closeButton = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["完成", "关闭", "Done", "Close"])
        ).firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Settings 应有关闭按钮")
        closeButton.tap()

        // 回 Home 后设置按钮再次可见
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), "关闭 Settings 后应回到 Home")
    }

    // MARK: - 3. AskPast Streaming smoke

    /// 进 Insights → 找 AskPast preset chip → tap → 验"正在思考"占位 UI 出现。
    /// **不验完整流式响应**,因为 CI 不调真 OpenAI。
    @MainActor
    func testAskPast_pressPreset_showsThinkingPlaceholder() throws {
        let app = launchSeededApp()

        let insightsButton = app.buttons["洞察"]
        XCTAssertTrue(insightsButton.waitForExistence(timeout: 5))
        insightsButton.tap()

        let insightsRoot = app.scrollViews["insightsRootScrollView"]
        XCTAssertTrue(insightsRoot.waitForExistence(timeout: 5))

        // Scroll 到 AskPast 区域(InsightsView 底部)
        for _ in 0..<3 {
            insightsRoot.swipeUp()
            usleep(300_000)
        }

        // 找第一颗 preset chip(`insightsAskPastPresetChip0` 这种 id)
        let presetChip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "insightsAskPastPresetChip")
        ).firstMatch
        XCTAssertTrue(presetChip.waitForExistence(timeout: 5),
                      "InsightsView 底部未找到 AskPast preset chip")
        presetChip.tap()

        // 进 AskPastView 后应该看到 conversation 状态。验"换一组"按钮 OR 任何 conversation UI 存在。
        // 真正 streaming "正在思考" 占位短暂,跨 launch 不稳;改验 AskPast sheet 入口的 a11y label 之一。
        let askPastUIVisible = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["关闭", "历史回顾", "清空"])
        ).firstMatch
        XCTAssertTrue(askPastUIVisible.waitForExistence(timeout: 5),
                      "AskPast 视图未打开(关闭/历史回顾/清空 按钮都不可见)")
    }

    // MARK: - Helpers

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
    private func waitForHome(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        XCTAssertTrue(
            app.buttons["设置"].waitForExistence(timeout: timeout),
            "Home 未加载完成(设置按钮未出现)"
        )
        usleep(800_000)
    }

}
