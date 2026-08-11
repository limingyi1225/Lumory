import SwiftUI
import CoreData
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SettingsView
//
// 按频率分三层：
// 1) 主层：常用 —— 主题整理、数据、提醒、隐私、语言、关于
// 2) 进阶子页：AI 重建、诊断 / 修复、危险数据操作 / DEBUG 工具
//
// 视觉去掉原来的 `listRowBackground(RoundedRectangle + shadow(0.2))` 重阴影，
// 让 iOS 26 inset-grouped 原生样式发挥作用，和首页的 Liquid Glass 对齐。

struct SettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>

    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    @AppStorage("home.showOnThisDay", store: AppGroup.userDefaults) private var showOnThisDay: Bool = true

    // 各种模态 / 确认态
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    @State private var recentlyDeletedCount = 0
    // 删除入口在进阶子页，但任务、确认和结果反馈必须由稳定的 Settings 根持有。
    // 否则用户确认后返回上一层，子页销毁会让完成/失败 alert 无处展示。
    @State private var showDeleteAllAlert = false
    @State private var showDeleteCompleteAlert = false
    @State private var isDeletingAllEntries = false
    @State private var deleteAllFailureMessage: String?

    @EnvironmentObject var importService: CoreDataImportService

    @ObservedObject private var aliasResolver = ThemeAliasResolver.shared
    @ObservedObject private var reminderService = ReminderService.shared
    @ObservedObject private var appLockService = AppLockService.shared
    @State private var showReminderDeniedAlert = false
    @State private var appLockEnableFailureMessage: String?
    /// 下次 reminder 实际 fire 的本地时间。**纯 SwiftUI computed**,直接根据 reminderService 的当前
    /// frequency / hour / minute 算 — 不依赖 UN pending list,所以拨 picker 立刻看到对的值,
    /// 没有 race。
    private var nextFireDate: Date? {
        reminderService.peekNextFireDate()
    }

    /// 防止用户在权限弹窗(首次 enable 的 await requestAuthorization 期间)双击 toggle 进入
    /// race:enable() 暂停时若 disable() 跑完再 resume,isEnabled 会被反复来回写。
    @State private var reminderToggleInFlight = false

    var body: some View {
        NavigationStack {
            Form {
                appHeaderSection
                homeDisplaySection
                reminderSection
                privacySection
                dataSection
                languageSection
                advancedSection
                aboutSection
            }
            #if os(macOS)
            .listStyle(.plain)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            // Form 的实色滚动背景必须隐藏,让 NavigationStack 根上的稳定 grouped 背景透出。
            .navigationTitle(NSLocalizedString("设置", comment: "Settings"))
            #if !os(macOS)
            // P1-Set-10 .inline → .automatic — iOS 26 large title 在滚顶时动态收缩,
            // .inline 强制小标题丢失这层动态。Settings 是单 sheet 入口,large 不显得头重。
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "Done")) {
                        isSettingsOpen = false
                    }
                    .fontWeight(.semibold)
                    .disabled(isDeletingAllEntries)
                }
            }
            #endif
            // F8 — iPad fullScreenCover(导入/导出有滚动列表+按钮组,formSheet 太窄)
            .lumoryAdaptiveModal(isPresented: $showImportSheet) {
                DiaryImportView()
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
            }
            .lumoryAdaptiveModal(isPresented: $showExportSheet) {
                DiaryExportView()
                    .environment(\.managedObjectContext, viewContext)
            }
            .task {
                // Settings 进来同步一次系统通知权限(用户可能在 Settings.app 改了)。
                await reminderService.refreshAuthorizationStatus()
                await refreshRecentlyDeletedCount()
            }
        }
        .alert(
            String(
                format: NSLocalizedString("删除全部 %d 条日记？", comment: "Delete all confirm title with count"),
                entries.count
            ),
            isPresented: $showDeleteAllAlert
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                #if canImport(UIKit)
                HapticManager.shared.destructive()
                #endif
                Task { await deleteAllEntries() }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString(
                "无法撤销。已合并的主题分组和 AI 历史对话也会一并清除。",
                comment: "Delete all undo side-effect message"
            ))
        }
        .alert(NSLocalizedString("删除完成", comment: "Deletion complete"), isPresented: $showDeleteCompleteAlert) {
            Button(NSLocalizedString("好", comment: "OK")) { isSettingsOpen = false }
        } message: {
            Text(NSLocalizedString("已删除所有日记", comment: "All entries deleted"))
        }
        .alert(
            NSLocalizedString("删除失败", comment: "Delete all failed alert title"),
            isPresented: Binding(
                get: { deleteAllFailureMessage != nil },
                set: { if !$0 { deleteAllFailureMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                deleteAllFailureMessage = nil
            }
        } message: {
            Text(deleteAllFailureMessage ?? "")
        }
        // 删除期间不允许下拉关闭 sheet；返回主设置页可以，但任务和反馈仍由本层持有。
        .interactiveDismissDisabled(isDeletingAllEntries)
        // Settings 的 Form row 是系统实体面，背景必须是全高、恒定的 grouped base。
        // 旧渐变在屏幕中段淡到纯白，白色 row 静止时融掉；滚进渐变区才突然出现边界。
        // 恒定 grouped 背景让卡片无论位于屏幕哪里都有同样的分离度，也不会在 push/pop 叠层。
        .background(Color.lumorySettingsGroupedBackground.ignoresSafeArea())
        // Settings 是 sheet,root toast overlay 被压住看不见;在 sheet 根挂一份。
        // 覆盖整个 NavigationStack,包括 push 进去的 AdvancedSettingsView —— 「清除 AI 回顾缓存」
        // 的 toast 在进阶子页触发,靠这层 overlay 浮出来。跟 InsightsView 等同 pattern。
        .lumoryToastOverlay()
    }

    // MARK: - Header

    /// 顶部：App 图标 + 名字 + 条目计数。纯装饰，没有按钮。
    /// (2026-05-14 用户决定:不显具体版本号 —— 用户不需要看到 build number。)
    @ViewBuilder
    private var appHeaderSection: some View {
        Section {
            HStack(spacing: 14) {
                Image("LumoryIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.primary.opacity(0.1), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Lumory", comment: "App name"))
                        .font(.title3.weight(.semibold))
                    Text(String(format: NSLocalizedString("%d 条日记", comment: "Entry count"), entries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Home display

    @ViewBuilder
    private var homeDisplaySection: some View {
        Section(header: Text(NSLocalizedString("首页", comment: "Home settings section"))) {
            Toggle(isOn: $showOnThisDay) {
                Label {
                    Text(NSLocalizedString("首页显示历史回忆", comment: "Show memory prompts on Home toggle"))
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                }
            }
        }
    }

    private var themeAliasSubtitle: String {
        let pending = aliasResolver.pendingCount
        let groups = aliasResolver.groups.count
        if pending == 0 && groups == 0 {
            return NSLocalizedString("把意指同一实体的标签合到一起", comment: "Theme alias subtitle empty")
        }
        var parts: [String] = []
        if pending > 0 { parts.append(String(format: NSLocalizedString("待审 %d 条", comment: "Pending"), pending)) }
        if groups > 0 { parts.append(String(format: NSLocalizedString("已合并 %d 组", comment: "Merged"), groups)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Reminder

    @ViewBuilder
    private var reminderSection: some View {
        Section(header: Text(NSLocalizedString("提醒", comment: "Reminder section"))) {
            Toggle(isOn: reminderToggleBinding) {
                Label {
                    Text(NSLocalizedString("写日记提醒", comment: "Reminder toggle"))
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "bell")
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                }
            }

            if reminderService.isEnabled {
                // 频率 — P1-Set-4:.segmented 在 Form .insetGrouped 内突兀,改 navigationLink
                // 跟下方 DatePicker 节奏一致(都是单行 row + 推 detail)。
                Picker(selection: frequencyBinding) {
                    ForEach(ReminderFrequency.allCases, id: \.self) { freq in
                        Text(freq.localizedLabel).tag(freq)
                    }
                } label: {
                    Label {
                        Text(NSLocalizedString("频率", comment: "Reminder frequency row"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(Color.accentColor)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                }
                .pickerStyle(.navigationLink)

                DatePicker(
                    selection: reminderTimeBinding,
                    displayedComponents: [.hourAndMinute]
                ) {
                    Label {
                        Text(NSLocalizedString("时间", comment: "Reminder time"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(Color.accentColor)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                }

                Toggle(isOn: contextualBodyBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("用近期主题作文案", comment: "Reminder contextual body toggle"))
                                .foregroundStyle(Color.primary)
                            Text(NSLocalizedString("通知正文会引用近期日记里的人和事(可能在锁屏显示)",
                                                   comment: "Reminder contextual body subtitle"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(Color.accentColor)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                    }
                }

                // 下次触发预览 —— 让用户拨完时间 / 频率有"哦下次会在某天某点弹"的确认感。
                // **纯函数 + computed property**:`peekNextFireDate()` 直接根据当前 frequency / hour /
                // minute 算,不读 UN pending list(那条路径有异步 race,拨 picker 时显示 stale 值)。
                // 任意 reminderService @Published 变化 SwiftUI 自动重 eval,不需要 .task / .onChange。
                if let nextDate = nextFireDate {
                    HStack(spacing: 12) {
                        Image(systemName: "alarm")
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("下次提醒", comment: "Reminder next fire row title"))
                                .foregroundStyle(Color.primary)
                            Text(LumoryDateFormatters.fullDateTime.string(from: nextDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .alert(
            NSLocalizedString("通知权限被拒", comment: "Notification denied alert title"),
            isPresented: $showReminderDeniedAlert
        ) {
            Button(NSLocalizedString("打开 设置", comment: "Open Settings")) {
                #if canImport(UIKit)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
            }
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("请在系统 设置 → Lumory → 通知 中开启,Lumory 才能在你设定的时间提醒你写日记。", comment: "Notification denied message"))
        }
    }

    private var reminderToggleBinding: Binding<Bool> {
        Binding(
            get: { reminderService.isEnabled },
            set: { newValue in
                guard !reminderToggleInFlight else { return }
                reminderToggleInFlight = true
                Task { @MainActor in
                    defer { reminderToggleInFlight = false }
                    if newValue {
                        let ok = await reminderService.enable()
                        if !ok {
                            showReminderDeniedAlert = true
                        }
                    } else {
                        await reminderService.disable()
                    }
                }
            }
        )
    }

    // 以下 3 个 Binding 不再包 Task —— update* 已是 sync,Binding setter 由 SwiftUI 在主线程
    // 调,直接 sync 调即可。包 Task 反而让快速连点的 setter 排进异步队列,前一次还没生效用户
    // 又点了,空挂任务。同时 toggleBinding 那里的 inflight gate 模式不需要扩展到这 3 个 ——
    // 这些都是纯 @Published 写 + requestReschedule(内部 gen 自带去抖)。
    private var frequencyBinding: Binding<ReminderFrequency> {
        Binding(
            get: { reminderService.frequency },
            set: { newValue in
                reminderService.updateFrequency(newValue)
            }
        )
    }

    private var contextualBodyBinding: Binding<Bool> {
        Binding(
            get: { reminderService.useContextualBody },
            set: { newValue in
                reminderService.updateUseContextualBody(newValue)
            }
        )
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = reminderService.hour
                comps.minute = reminderService.minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                reminderService.updateTime(
                    hour: comps.hour ?? 21,
                    minute: comps.minute ?? 0
                )
            }
        )
    }

    // MARK: - Privacy

    /// 隐私 section — 目前只有 App 锁。Toggle on 走 Face ID / 设备密码确认 → 启用失败(取消 / 设备
    /// 不支持)显示 alert。Toggle off 直接禁用,无需认证。
    @ViewBuilder
    private var privacySection: some View {
        Section(header: Text(NSLocalizedString("隐私", comment: "Privacy section"))) {
            Toggle(isOn: appLockBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("App 锁", comment: "App lock toggle"))
                            .foregroundStyle(Color.primary)
                        Text(NSLocalizedString("回到 App 时用 Face ID / 设备密码解锁",
                                               comment: "App lock subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "faceid")
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                }
            }
        }
        .alert(
            NSLocalizedString("无法启用 App 锁", comment: "App lock enable failed alert title"),
            isPresented: Binding(
                get: { appLockEnableFailureMessage != nil },
                set: { if !$0 { appLockEnableFailureMessage = nil } }
            )
        ) {
            // P1-Set-8 加"去系统设置"快捷入口 — Face ID 拒绝 / 未授权时引导用户开权限,而不是只关 alert。
            #if canImport(UIKit)
            Button(NSLocalizedString("去系统设置", comment: "Open system Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) { }
        } message: {
            Text(appLockEnableFailureMessage ?? "")
        }
    }

    /// App lock toggle 的 binding。enable 走 async 认证(在 Face ID alert 弹出前先 set false 让
    /// UI 不停在"启用中"假象,认证完拨真值)。disable 直接同步禁用。
    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { appLockService.isEnabled },
            set: { wantOn in
                if wantOn {
                    Task {
                        let ok = await appLockService.enable()
                        if !ok {
                            appLockEnableFailureMessage = NSLocalizedString(
                                "需要在系统设置里先开启 Face ID 或设备密码,且认证通过后才能启用。",
                                comment: "App lock enable failure message"
                            )
                        }
                    }
                } else {
                    appLockService.disable()
                }
            }
        )
    }

    @ViewBuilder
    private var dataSection: some View {
        Section(header: Text(NSLocalizedString("数据", comment: "Data"))) {
            // 主题合并直接影响日记数据如何聚合与展示，放在数据区第一项。
            NavigationLink {
                ThemeAliasManagementView()
                    .environment(\.managedObjectContext, viewContext)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tag.circle")
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(NSLocalizedString("合并主题", comment: "Merge themes row"))
                                .foregroundStyle(Color.primary)
                            if aliasResolver.redDotVisible {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel(NSLocalizedString("有待审建议", comment: "A11y red dot"))
                            }
                        }
                        Text(themeAliasSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Button {
                showImportSheet = true
            } label: {
                settingsLabel(NSLocalizedString("导入日记", comment: "Import"), icon: "square.and.arrow.down", tint: .accentColor)
            }

            Button {
                showExportSheet = true
            } label: {
                settingsLabel(NSLocalizedString("导出日记", comment: "Export"), icon: "square.and.arrow.up", tint: .accentColor)
            }

            NavigationLink {
                RecentlyDeletedView()
                    .environment(\.managedObjectContext, viewContext)
                    .onDisappear {
                        Task { await refreshRecentlyDeletedCount() }
                    }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("最近删除", comment: "Recently deleted"))
                            .foregroundStyle(Color.primary)
                        if recentlyDeletedCount > 0 {
                            Text(String(format: NSLocalizedString("保留中 %d 条", comment: "Recently deleted count"), recentlyDeletedCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

        }
    }

    @MainActor
    private func refreshRecentlyDeletedCount() async {
        recentlyDeletedCount = await RecentDeletedEntryStore.count()
    }

    // MARK: - Language

    @ViewBuilder
    private var languageSection: some View {
        Section(header: Text(NSLocalizedString("语言", comment: "Language"))) {
            Picker(NSLocalizedString("应用语言", comment: "App language picker"), selection: $appLanguage) {
                Text("简体中文").tag("zh-Hans")
                Text("English (US)").tag("en")
            }
            // P1-Set-3 .inline 占两行无 label → .navigationLink 单行 + 推 detail 选,跟下方 row 节奏一致。
            .pickerStyle(.navigationLink)
            // 切语言后,主屏 widget 还停在旧 locale 上 —— 主动 reload timeline 让 widget 走新 locale。
            // 不会立刻刷,WidgetKit 自己排时间,但下一次系统调度会用新 locale。
            .onChange(of: appLanguage) { _, _ in
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        Section(header: Text(NSLocalizedString("进阶", comment: "Advanced"))) {
            NavigationLink {
                AdvancedSettingsView(
                    isSettingsOpen: $isSettingsOpen,
                    isDeletingAllEntries: $isDeletingAllEntries,
                    hasEntries: !entries.isEmpty,
                    onRequestDeleteAll: { showDeleteAllAlert = true }
                )
                    .environment(\.managedObjectContext, viewContext)
            } label: {
                settingsLabel(
                    NSLocalizedString("诊断、修复与分项控制", comment: "Advanced tools"),
                    icon: "slider.horizontal.3",
                    tint: .secondary
                )
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section(header: Text(NSLocalizedString("关于", comment: "About"))) {
            if let contactURL = URL(string: "mailto:me@limingyi.com") {
                Link(destination: contactURL) {
                    settingsLabel(
                        NSLocalizedString("联系开发者", comment: "Contact developer"),
                        icon: "envelope",
                        tint: .accentColor
                    )
                }
            }
        }
    }

    // MARK: - Small helpers

    private func settingsLabel(_ title: String, icon: String, tint: Color) -> some View {
        Label {
            Text(title)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
        }
    }

    @MainActor
    private func deleteAllEntries() async {
        guard !isDeletingAllEntries else { return }
        isDeletingAllEntries = true
        defer { isDeletingAllEntries = false }

        // Service 会在确认后重新 fetch，包含 alert 展示期间由 CloudKit 同步进来的条目。
        let didDelete = await SettingsEntryDeletionService.deleteAll(viewContext: viewContext)
        if didDelete {
            showDeleteCompleteAlert = true
        } else {
            #if canImport(UIKit)
            HapticManager.shared.notification(.error)
            #endif
            deleteAllFailureMessage = NSLocalizedString(
                "删除暂时无法完成。请稍后再试。如果反复失败,先确认 iCloud 已完成同步,或重启 App 后再试。",
                comment: "Delete all failed body"
            )
        }
    }

}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(isSettingsOpen: .constant(true))
            .environmentObject(CoreDataImportService())
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }
}
