---
name: swift-verify
description: 对 Lumory iOS target 跑 xcodebuild build 或 test,抓错误摘要。改完 Swift 代码想确认编译 / 单测过时用。用户说"build 能过吗"、"跑下编译"、"测试过了吗"触发。
---

# Swift 编译 + 测试检查

Lumory 没有 pre-commit lint,改完 Swift"看起来对"但编译不过是常见状态。这个 skill 把 build / test 串起来并只抓有用错误。

## 触发场景
- 改完 Service / View / Model 想确认编译过
- 改完后想跑一次单测 / UI 测试
- 用户问 build 或 test 状态

## 命令

| 目的 | 命令 |
|---|---|
| Build Debug | `xcodebuild -project Lumory.xcodeproj -scheme Lumory -configuration Debug build 2>&1 \| tail -80` |
| 跑测试 | `xcodebuild test -project Lumory.xcodeproj -scheme Lumory -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 \| tail -120` |
| 清理 DerivedData | `./clean-build.sh` |
| 彻底清(含 ModuleCache / .swiftpm) | `./deep-clean.sh` |
| DB 损坏恢复 | `./clean-corrupted-db.sh` 或 `Scripts/reset-database.sh` |

## 错误读取

构建失败时抓:
- `error:` 开头的行(后面接文件:行号:列号)
- `** BUILD FAILED **` 之前 20 行上下文
- **忽略** `warning:` 和 deprecated 提示

测试失败时抓:
- `XCTAssertXxx failed` 开头
- `Test Case '-[XXX testYYY]' failed`
- 崩溃时看 `Abort Cause`(9005 通常是 main thread 死锁,见下)

## Lumory 特有陷阱

1. **scheme / target 都叫 `Lumory`**,不是 `Chronote`(productName 遗留名)
2. **Xcode 用 `PBXFileSystemSynchronizedRootGroup`** —— 新加 `.swift` 直接放 `Chronote/` 目录就自动进 target,**不要**手编 `project.pbxproj`
3. **UI test target 配置**:`TEST_TARGET_NAME = Lumory`(历史是 `Chronote`,已修)。`-only-testing:ChronoteUITests/ScreenshotTests/testXxx` 走 UI test bundle 名 `ChronoteUITests`
4. **`xcodebuild test` 默认 clone simulator**,跑 UI 测试 / 截图时要 `-parallel-testing-enabled NO`,不然 `simctl status_bar override` 不生效
5. **main thread 死锁(SIGTRAP / Abort 9005...)**:从 main 调 `bg.performAndWait` 时,block 内**不能** `DispatchQueue.main.sync`。看到这个 abort 先查 background context 里的 main-thread 调用

## 编译通过但运行崩

常见几个原因:
- **CoreData schema 不兼容**:改了 `DiaryEntry` 字段但没升版本 → 看 `PersistenceController` 加载日志
- **CloudKit schema 冲突**:加了非 optional / 没默认值的字段 → 跑真机或 `CKContainer.shared().schema` 检查
- **embedding / themes 解码失败**:V1 格式的 magic 不对 → 看 `DiaryEntry+Extensions`

碰到运行崩,先查是不是以上三类,再深挖。
