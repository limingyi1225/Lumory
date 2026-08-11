import CoreData
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }()

    @State private var records: [RecentDeletedEntryStore.RecordPreview] = []
    @State private var isLoading = true
    @State private var operationInFlight: UUID?
    @State private var restoreFailureMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if records.isEmpty {
                EmptyStateView(
                    systemImage: "trash",
                    title: NSLocalizedString("最近没有删除的日记", comment: "Recently deleted empty title"),
                    message: NSLocalizedString("单条删除会在这里保留 30 天。错删时可以从这里恢复。", comment: "Recently deleted empty message"),
                    size: .compact
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section(
                    footer: Text(NSLocalizedString("这里仅保留单条删除的日记 30 天。清空全部日记仍按高风险操作处理,不会进入最近删除。", comment: "Recently deleted footer"))
                ) {
                    ForEach(records) { record in
                        row(for: record)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await deletePermanently(record) }
                                } label: {
                                    Label(NSLocalizedString("彻底删除", comment: "Delete permanently"), systemImage: "trash.slash")
                                }

                                Button {
                                    Task { await restore(record) }
                                } label: {
                                    Label(NSLocalizedString("恢复", comment: "Restore"), systemImage: "arrow.uturn.backward")
                                }
                                .tint(.accentColor)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(NSLocalizedString("最近删除", comment: "Recently deleted"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if hSizeClass == .regular {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(NSLocalizedString("关闭", comment: "Close"))
                }
            }
        }
        .task { await reload() }
        .alert(
            NSLocalizedString("恢复失败", comment: "Restore failed alert title"),
            isPresented: Binding(
                get: { restoreFailureMessage != nil },
                set: { if !$0 { restoreFailureMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "OK"), role: .cancel) {
                restoreFailureMessage = nil
            }
        } message: {
            Text(restoreFailureMessage ?? "")
        }
        .lumoryToastOverlay()
    }

    @ViewBuilder
    private func row(for record: RecentDeletedEntryStore.RecordPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color.moodSpectrum(value: record.moodValue))
                    .frame(width: 8, height: 8)
                Text(entryDateLabel(record.entryDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(daysLeftLabel(record.expiresAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(record.displayText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 10) {
                if record.imageCount > 0 {
                    Label(
                        String(format: NSLocalizedString("%d 张照片", comment: "Recently deleted photo count"), record.imageCount),
                        systemImage: "photo"
                    )
                }
                if record.hasAudio {
                    Label(NSLocalizedString("录音", comment: "Recently deleted audio label"), systemImage: "waveform")
                }
                Spacer(minLength: 0)
                Button {
                    Task { await restore(record) }
                } label: {
                    if operationInFlight == record.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(NSLocalizedString("恢复", comment: "Restore"))
                    }
                }
                // 外层 archive card 已经是 glass；恢复是卡内次级动作,用 borderless tint
                // 保留交互层级,不再叠第二层 glass rim / shadow。
                .buttonStyle(.borderless)
                .tint(.accentColor)
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(operationInFlight != nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: LumoryCornerRadius.card, tint: Color.moodSpectrum(value: record.moodValue), tintStrength: 0.08, interactive: false)
    }

    private func reload() async {
        isLoading = true
        records = await RecentDeletedEntryStore.previews()
        isLoading = false
    }

    @MainActor
    private func restore(_ record: RecentDeletedEntryStore.RecordPreview) async {
        guard operationInFlight == nil else { return }
        operationInFlight = record.id
        defer { operationInFlight = nil }
        let ok = await RecentDeletedEntryStore.restore(archiveID: record.id, into: viewContext)
        if ok {
            #if canImport(UIKit)
            HapticManager.shared.complete()
            #endif
            LumoryToastCenter.shared.show(
                NSLocalizedString("已恢复", comment: "Recently deleted restore success toast"),
                severity: .success
            )
            await reload()
        } else {
            #if canImport(UIKit)
            HapticManager.shared.notification(.error)
            #endif
            restoreFailureMessage = NSLocalizedString("这条日记暂时无法恢复。请稍后再试。", comment: "Recently deleted restore failed message")
        }
    }

    private func deletePermanently(_ record: RecentDeletedEntryStore.RecordPreview) async {
        guard operationInFlight == nil else { return }
        operationInFlight = record.id
        defer { operationInFlight = nil }
        await RecentDeletedEntryStore.delete(archiveID: record.id)
        #if canImport(UIKit)
        HapticManager.shared.destructive()
        #endif
        await reload()
    }

    private func entryDateLabel(_ date: Date?) -> String {
        guard let date else { return NSLocalizedString("无日期", comment: "No date") }
        return LumoryDateFormatters.mediumDate.string(from: date)
    }

    private func daysLeftLabel(_ expiresAt: Date) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0)
        if days == 0 {
            return NSLocalizedString("今天过期", comment: "Recently deleted expires today")
        }
        return String(
            format: NSLocalizedString("还剩 %d 天", comment: "Recently deleted days left"),
            days
        )
    }
}
