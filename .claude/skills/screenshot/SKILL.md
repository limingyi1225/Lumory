---
name: screenshot
description: 跑 Lumory 的 App Store 上架截图流水线(iPhone / iPad),封装 simctl 状态栏 override + UI test + xcresult 导出。用户说"截图"、"生成上架截图"、"app store screenshot"、"出一组截图"时触发。
---

# App Store 截图生成

把 `Scripts/generate-screenshots.sh` 跑通,输出 6 张固定尺寸截图到 `Screenshots/zh-Hans/` 或 `Screenshots/zh-Hans-iPad/`。

## 触发场景
- 用户要生成 App Store 上架截图
- 预览 UI 当前状态到一组固定分辨率
- iPad / iPhone 两种规格之间切换

## 命令

| 场景 | 命令 | 输出 |
|---|---|---|
| iPhone(默认 1320×2868) | `./Scripts/generate-screenshots.sh` | `Screenshots/zh-Hans/` |
| iPad(2064×2752) | `./Scripts/generate-screenshots.sh ipad` | `Screenshots/zh-Hans-iPad/` |
| 指定 simulator | `LUMORY_SIM="iPhone 13 Pro Max - Lumory" ./Scripts/generate-screenshots.sh` | 同上 |

## 必须知道的坑(来自 CLAUDE.md)

1. **`-parallel-testing-enabled NO -disable-concurrent-destination-testing` 必加**
   `xcodebuild test` 默认会 clone simulator,`simctl status_bar override` **不继承到 clone**,会导致截图角上是真实电量 / 真实时间。脚本里已处理,别手动改掉。

2. **样例数据是启动参数触发,不是跑前准备**
   `-LumoryUITestSampleData YES` 触发 `UITestSampleData.seedIfNeeded`,会**同步擦库**后种入 30 条手写 + ~60 条模板化样例日记(主角"林子衿")。跑完别以为数据是你的。

3. **权限弹窗会盖首屏**
   Screenshot 模式下 `requestPermissions()` **必须 early return**(已通过 `UITestSampleData.isActive` 判断)。如果你刚改过权限流程,确认这条没被破坏。

4. **.xcresult 导出用新 API**
   `xcrun xcresulttool export attachments --path BUNDLE --output-path DIR`(Xcode 16+),配 `manifest.json` 把 UUID 文件名映射成人读名。**不要**用 deprecated 的 `--legacy --format json`。

5. **iPad `.sheet` 是居中 formSheet**
   Insights / AskPast 是 sheet 打开,iPad 上会显示成浮在 Home 上的小卡 —— 这是 SwiftUI 默认。要全屏得改 `.fullScreenCover` 或加 `.presentationSizing(.fitted/.full)`。

## Target / Scheme 名
- scheme、target、productName 都叫 **`Lumory`**
- `productName` 遗留写的是 `Chronote`(别奇怪)
- UI test bundle 还叫 **`ChronoteUITests`**,`-only-testing:ChronoteUITests/ScreenshotTests/testXxx` 用这个名

## 常见失败排查

| 症状 | 原因 | 修 |
|---|---|---|
| 角上电量 80% / 真实时间 | simulator 被 clone 了 | 检查 `-parallel-testing-enabled NO` 还在不 |
| Speech / Mic 权限弹窗挡住首屏 | `isActive` 判断被破坏 | 看 `ChronoteApp.requestPermissions()` early return |
| "UITargetAppPath should be provided" | UI test target 的 `TEST_TARGET_NAME` 错 | 应为 `Lumory`(之前是 `Chronote`) |
| 首屏没数据 | 样例数据没 seed | 确认启动参数 `-LumoryUITestSampleData YES` 传了 |
