---
paths:
  - "ChronoteTests/**"
  - "ChronoteUITests/**"
  - "Scripts/**"
---

# Lumory 测试 / 截图 / 脚本约定

## xcodebuild test 强制串行

**`xcodebuild test` 默认会 clone 指定的 simulator**(运行时 `RUN_DESTINATION_DEVICE_NAME = "Clone N of iPhone X"`),而 `simctl status_bar override` **只对原始 sim 生效,不继承到 clone**。截图脚本必须加 `-parallel-testing-enabled NO -disable-concurrent-destination-testing` 强制走原始 sim,否则状态栏角上是真实电量 / 真实时间。

**纯 unit test 跑全 ChronoteTests 也建议加这俩 flag** —— 不加每次跑 pass/fail 数都不一样(149 / 138 / 109…),失败长 `Crash: Lumory at <external symbol>` + duration `0.000s`,看着像真崩,实际是 simulator clone 不稳;加 flag 后 149/0 稳定。

**两次 `xcodebuild test` 不能并发** —— 第二个启动让第一个的 test 过程进入同样的 0.000s 假崩。重跑前 `pkill -f "xcodebuild test"; sleep 2`。

## 真的 SIGABRT vs clone flake

**真的 SIGABRT 不是 clone flake**:macOS `~/Library/Logs/DiagnosticReports/Lumory-*.ips` 有 EXC_CRASH/SIGABRT + Obj-C 异常栈底是 `executeFetchRequest:error:` / SwiftUI `FetchRequest.update`,**这是 PersistenceController 多 NSManagedObjectModel 实例 ambiguity** —— 测试里 `PersistenceController(inMemory: true)` 出现 N 次,每次都重新加载 `.xcdatamodeld` 生成新 model,Core Data `+[DiaryEntry entity]` "Failed to find a unique match"。修法:`PersistenceController.cachedModel` 静态共享 `NSManagedObjectModel`(2026-04-29 落地)。看到 `.ips` 有 Core Data 栈先怀疑这条,而不是默认归类成 clone flake。

## .xcresult 提取

用 Xcode 16+ 自带的 `xcrun xcresulttool export attachments --path BUNDLE --output-path DIR`(配合 `manifest.json` 把 UUID 文件名映射回 `suggestedHumanReadableName`),不需要装 `xcparse`,也别用 deprecated 的 `--legacy --format json` 老 API。

**只想要 pass/fail 摘要 + 失败列表**:

```bash
xcrun xcresulttool get test-results summary --path X.xcresult | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('passed=',d['passedTests'],'failed=',d['failedTests'])
[print(' -',f['testIdentifierString'],':',f['failureText'][:80]) for f in d.get('testFailures',[])]
"
```

比 grep 原始 xcodebuild log 干净 10 倍。

## Screenshot 模式

`-LumoryUITestSampleData YES` 启动参数让 `PersistenceController.shared` 自动构造 in-memory store + `seedIfNeeded` 种 ~90 条样例(主角"林子衿")。

**`requestPermissions()` 必须 early return**(`if UITestSampleData.isActive { return }`),否则 SFSpeech / Mic 弹窗盖在 Home 上把首屏截烂。**`ReminderService.enable()` 同样要早返**(防 toggle 被意外触发时通知权限弹窗盖住截图);任何"主动 requestAuthorization"路径都得过这道闸。

`Scripts/generate-screenshots.sh` 默认 iPhone 17 Pro Max → `simctl status_bar override`(9:41 / 满电) → `xcodebuild test -only-testing ... -parallel-testing-enabled NO` → `xcresulttool export attachments`。

iPad:`./Scripts/generate-screenshots.sh ipad` → 2064×2752 → `Screenshots/zh-Hans-iPad/`。任意机型:`LUMORY_SIM="iPhone 13 Pro Max - Lumory" ./Scripts/generate-screenshots.sh`。

iPad 上 `lumoryAdaptiveModal` 走 `fullScreenCover`(`shouldUseExpandedModal: isPad || hSizeClass == .regular`,见 [LumoryAdaptivePresentation.swift:12](Chronote/Views/Components/LumoryAdaptivePresentation.swift:12)),Insights / AskPast / Settings 等都全屏覆盖,iPad 截图跟 iPhone 视觉一致。

## bash PIPESTATUS

**`cmd1 | cmd2 || true` 会覆盖 `PIPESTATUS`**。`|| true` 之后 `${PIPESTATUS[0]}` 只剩 `true` 的 exit code,原 pipeline 状态丢光。需要真实 exit code 时改用 `set +e` + 直接 pipeline(不加 `|| true`),然后读 `PIPESTATUS[0]`,最后 `set -e`(参见 `Scripts/generate-screenshots.sh`)。
