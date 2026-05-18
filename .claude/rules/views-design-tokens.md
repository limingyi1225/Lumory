---
paths:
  - "Chronote/Views/**"
---

# Lumory UI design tokens + view-layer 约定

不要再手贴数值,从 token 拿。这套 rule 只在编辑 `Chronote/Views/**` 下文件时加载。

## 字号

用语义 `.body` / `.title3` / `.footnote` / `.callout` 等,**不要** `.font(.system(size: N))`(2026-05-17 audit:`Chronote/` 全仓 37 处 `.system(size:` 残留,日记 summary 同一字段在 3 处用 3 个字号 16/15/17)。例外:monospaced 计时(确实需要等宽)、widget 字号约束(LumoryWidgets 另算 8 处)。

## 圆角

用 `LumoryCornerRadius.card` (16) / `.chip` (22) / `.inline` (12)。规则:**内容卡 16,toast / overlay 22,inline banner 12**。2026-05-17 audit:`Chronote/Views` 共 45 处硬编码 `cornerRadius:`,top values 14(×10)/ 8(×8)/ 4(×7)/ 12(×5)/ 16(×3);说明 `.thumbnail`(8)在 view 层确实有需要,要做一致性 sweep 时再加这个 token(2026-05 删除时全仓 0 caller,现在 8(×8)说明用例长出来了)。

## 动画

token 化的:`AnimationConfig.toast`(0.34/0.86)/ `.bannerAppear`(0.42/0.86)/ `.bannerCollapse`(0.32/0.9)+ 老的 `fastResponse / standardResponse / smoothTransition / gentleSpring / stiffSpring`。`modalScale / scrollSnap / itemRemoval` 3 个 P1-T3 token 在 2026-05 删除时全仓 0 caller,要做 modal / scroll / list-row 一致性 sweep 时再加回。**新代码手贴 `.spring(response:dampingFraction:)` 之前先想想要不要在 `AnimationConfig` 加 token**。

## Haptic 规则(写一次,所有触发点对齐)

- **自定义 Button-shape 进 detail 卡(日记 / 主题 / Settings 自定义 row)统一 `.light` impact**。
- Form 内置 row / NavigationLink **不加**(系统已自带反馈)。
- **destructive** 操作 `.medium` impact;失败 `.error` notification;完成 `.success` notification。
- **主 send / save / delete 是两段反馈** — tap 入口 `.light` impact 让用户立刻知道按到了 + 完成时 `.success` notification + LumoryToast。既不是三连(吵)也不是只有完成(中间空白)。

## PressableScaleButtonStyle 用法

- **所有 liquidGlassCard + Button 组合**默认套这个 style;
- 系统 Form 内置 row / NavigationLink **不动**(系统 highlight 已经够);
- destructive 红色 prominent button **不套**(自带反馈,叠加显得肉)。

## Sheet 关闭按钮文案规则

- **"取消"** = 撤销正在进行的事(stream task / 编辑 / 表单填一半);
- **"关闭"** = 退出只读视图(全屏图片 viewer / 详细报告 / 别人写好的内容);
- **"完成"** = 提交所有更改(编辑保存 / 表单提交)。

例:AskPastView 关闭时取消 stream task → 文案是"取消";SyncDiagnostic 全屏报告 → "完成"。

## DateFormatter

用 `LumoryDateFormatters.timeShort / .monthDay / .weekdayShort / .weekdayFull / .fullDateTime / .isoDate / .monthDayWeekday / .twentyFourHourTime / .mediumDate / .longDateShortTime / .monthShort` + 语言感知 accessor `.monthDay(language:) / .weekdayFull(language:) / .dayNumber(language:) / .monthShortLocalized(language:) / .timeShortLocalized(language:) / .longDate(language:)`。**不要**在 view 里 `let f = DateFormatter()` 局部 cache(reviewer 历史数到 5 处)。`DateFormatter` 自身线程安全 since iOS 7,共享实例没问题。

**POSIX-locked token 不归 view 层**但同库:`fileTimestamp`(文件名)/ `isoDatePOSIX`(LLM prompt)/ `httpDate`(RFC 7231)走 service 用,绕过 `Locale.current` 防本地数字系。详见 `ios-codebase.md` "本地化字符串" 段。

## 删除日记走 toast,不走 confirmation alert

接 `EntryDeletionUndoService.shared.register(snapshot:)` + `LumoryToastCenter.shared.show("已删除", severity: .success, duration: 4, action: ...)`,toast 上有"撤销"按钮 4 秒可点。4 处入口都改了:`HomeView.deleteEntry` / `DiaryDetailView.deleteEntry` / `ThemeFilteredEntriesView.deleteEntry` / `PointDetailSheet.deleteEntry`。

**保留** alert 的:`SettingsView` 删除全部日记(批量,不可单条 undo)/ `ThemeFilteredEntriesView` 删除整个主题(影响多 entry)/ `HomeView` 删除录音(子操作,不影响 entry)。**新加单 entry 删除入口走 undo 模式,不要回到 alert**。

## Toast 入口

统一用 `LumoryToastCenter.shared.show(message, severity:)`,**不要**再写 local `@State toastMessage` + 自定义 overlay。带 action 的 toast(撤销 / 重试)用 `LumoryToastCenter.Action(label:perform:)`。

如果 view 是 sheet 内容根 + 触发自身 toast,在 root 加 `.lumoryToastOverlay()`(已挂 5 处:InsightsView / ThemeAliasManagementView / DiaryDetailView / PointDetailSheet / ThemeFilteredEntriesView)。`ChronoteApp` body 已挂 root overlay,sheet 内层重挂是因为 sheet 把 root overlay 压住看不见。同 singleton 多层渲染同一条 toast,系统 z-order 保证只一条可见。

**Toast 整条 capsule 都是 hit area** —— 有 action 时 tap 任意位置 = 触发 action(等同 Apple Photos 删除 toast),没 action 时 tap = dismiss。距底部 52pt(原 36 太近,user 拇指从右下伸过去容易穿透到下方 timeline row 进 detail)。

## Form / Sheet / NavigationStack 视觉细节

- **`Form` `.insetGrouped` 内放 `liquidGlassCard` 的 row 必须 `listRowInsets(leading: 16, trailing: 16)`,不能 0**。iOS 26 Form 给每个 row 包一层系统 rounded inset chrome,liquidGlassCard 顶满会跟 chrome 边缘重合产生"突兀阴影 / 双圆角";16/16 给卡留呼吸空间,只显示自己的玻璃边。`pendingCard` / HomeView 时间线 row / `ThemeAliasManagementView.groupRow` 都是这个 pattern。
- **Sheet 用 `Color(UIColor.systemBackground)` 纯白底,不要再退回 Material**(2026-05-05 4 轮迭代结论)。`thinMaterial → regularMaterial → thickMaterial → ultraThickMaterial` 用户每一档都反馈"还透 / Settings 子页面 pop 暗一闪"。**根因不是 Material 厚度**,是 SwiftUI 在 NavigationStack push/pop transition 中间帧把 sheet material 透出露出后方被 dim 的 Home;Material 任何一档都救不了,只有 `Color` 实色完全避开这条路径(SwiftUI 不对 Color sheet 做 cross-fade dim)。代价:失去 iOS 26 玻璃感。`lumorySheetDecoration()` 已锁纯白 + 28pt 圆角顶。
- **NavigationStack 内 sub-page 不要自挂跟 parent 同款 `backgroundGradient`**。Settings 跟 ThemeAliasManagementView 各自挂一份 `Color.accentColor.opacity(0.08)` gradient → push/pop transition 中间帧两层 alpha 累计 = 视觉变暗一闪。修法:**parent 挂 backgroundGradient,sub-page 不挂**(透出 sheet 的纯白底统一)。
