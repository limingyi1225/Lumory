import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SettingsView
//
// 按频率分三层：
// 1) 主层：常用 —— AI 一键索引、数据、iCloud、语言、关于
// 2) 进阶子页：诊断 / 修复 / 分项索引 / DEBUG 工具
//
// 视觉去掉原来的 `listRowBackground(RoundedRectangle + shadow(0.2))` 重阴影，
// 让 iOS 26 inset-grouped 原生样式发挥作用，和首页的 Liquid Glass 对齐。

struct SettingsView: View {
    @Binding var isSettingsOpen: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DiaryEntry.date, ascending: false)]
    ) private var entries: FetchedResults<DiaryEntry>

    @AppStorage("appLanguage") private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()

    // 各种模态 / 确认态
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    @State private var showDeleteAllAlert = false
    @State private var showDeleteCompleteAlert = false
    @State private var isDeletingAllEntries = false

    @EnvironmentObject var importService: CoreDataImportService
    @EnvironmentObject var syncMonitor: CloudKitSyncMonitor

    @ObservedObject private var aliasResolver = ThemeAliasResolver.shared
    @ObservedObject private var reminderService = ReminderService.shared
    @State private var showReminderDeniedAlert = false
    /// 防止用户在权限弹窗(首次 enable 的 await requestAuthorization 期间)双击 toggle 进入
    /// race:enable() 暂停时若 disable() 跑完再 resume,isEnabled 会被反复来回写。
    @State private var reminderToggleInFlight = false

    var body: some View {
        NavigationStack {
            Form {
                appHeaderSection
                aiIndexSection
                reminderSection
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
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("设置", comment: "Settings"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "Done")) {
                        isSettingsOpen = false
                    }
                    .fontWeight(.semibold)
                }
            }
            #endif
            .sheet(isPresented: $showImportSheet) {
                DiaryImportView()
                    .environmentObject(importService)
                    .environment(\.managedObjectContext, viewContext)
            }
            .sheet(isPresented: $showExportSheet) {
                DiaryExportView()
                    .environment(\.managedObjectContext, viewContext)
            }
            .alert(NSLocalizedString("删除完成", comment: "Deletion complete"), isPresented: $showDeleteCompleteAlert) {
                Button(NSLocalizedString("好", comment: "OK")) { isSettingsOpen = false }
            } message: {
                Text(NSLocalizedString("已删除所有日记", comment: "All entries deleted"))
            }
            .task {
                // Settings 进来同步一次系统通知权限(用户可能在 Settings.app 改了)。
                await reminderService.refreshAuthorizationStatus()
            }
        }
    }

    // MARK: - Header

    /// 顶部：App 图标 + 名字 + 版本 + 条目计数。纯装饰，没有按钮。
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
                    Text(versionString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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

    // MARK: - AI(合并主题 + 重建索引一起放这里)

    @ViewBuilder
    private var aiIndexSection: some View {
        Section(header: Text(NSLocalizedString("AI 与索引", comment: "AI section header"))) {
            // 第一项:合并主题(原 themeAliasSection,搬过来)
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
            // 第二项:重建全部 AI 分析(原 OneClickRebuildRow)
            OneClickRebuildRow()
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
                // 频率 —— 段控件,iOS 26 自动液态玻璃
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
                .pickerStyle(.segmented)

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

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section(header: Text(NSLocalizedString("数据", comment: "Data"))) {
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

            Button {
                showDeleteAllAlert = true
            } label: {
                HStack {
                    settingsLabel(NSLocalizedString("删除所有日记", comment: "Delete all"), icon: "trash", tint: .red)
                    if isDeletingAllEntries {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDeletingAllEntries)
            .alert(NSLocalizedString("确认删除所有日记？", comment: "Confirm delete all"), isPresented: $showDeleteAllAlert) {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    Task {
                        let didDelete = await deleteAllEntries()
                        if didDelete {
                            showDeleteCompleteAlert = true
                        }
                    }
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("此操作无法撤销。已合并的主题分组也会一并清除。", comment: "Delete all undo + alias warning"))
            }
        }
    }

    // MARK: - Language

    @ViewBuilder
    private var languageSection: some View {
        Section(header: Text(NSLocalizedString("语言", comment: "Language"))) {
            Picker("", selection: $appLanguage) {
                Text("简体中文").tag("zh-Hans")
                Text("English (US)").tag("en")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        Section(header: Text(NSLocalizedString("进阶", comment: "Advanced"))) {
            NavigationLink {
                AdvancedSettingsView(isSettingsOpen: $isSettingsOpen)
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

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// 很淡的顶部 mood-tinted 渐变，让 Settings 和首页保持同一种空气感。
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.08),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .center
        )
    }

    // MARK: - Actions

    private func deleteAllEntries() async -> Bool {
        isDeletingAllEntries = true
        defer { isDeletingAllEntries = false }
        return await SettingsEntryDeletionService.deleteAll(entries: Array(entries), viewContext: viewContext)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(isSettingsOpen: .constant(true))
            .environmentObject(CoreDataImportService())
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }
}
