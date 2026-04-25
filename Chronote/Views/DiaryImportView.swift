import SwiftUI
import CoreData

struct DiaryImportView: View {
    @EnvironmentObject var importService: CoreDataImportService
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText: String = ""
    @State private var showResultAlert: Bool = false
    @State private var resultSucceeded: Int = 0
    @State private var resultFailed: Int = 0

    // **三种结束态**:成功(含 succeeded/failed 计数) / 没识别到日记 / 真错误(网络等)。
    // 旧实现只看 succeeded/failed 数字 ——「parser 抛错」和「parser 返回 0 条」都被当成
    // "成功导入 0 条日记" 给用户,误导很大。这里用枚举把三种态分开,并在 alert 里走不同文案。
    private enum ImportOutcome {
        case finished(succeeded: Int, failed: Int)
        case noEntriesDetected
        case error(String)
    }
    @State private var outcome: ImportOutcome = .finished(succeeded: 0, failed: 0)
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(NSLocalizedString("导入日记", comment: "Import diaries title"))
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(NSLocalizedString("将你的日记粘贴到下面，支持多篇日记连贴。", comment: "Import instruction"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ZStack(alignment: .topLeading) {
                    if pastedText.isEmpty {
                        Text(NSLocalizedString("在此粘贴日记内容…", comment: "Paste placeholder"))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(12)
                    }
                    TextEditor(text: $pastedText)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .frame(minHeight: 200)
                }

                // **进度 + 结果反馈**：以前按钮一按就 dismiss，用户既看不到进度、也看不到失败数量。
                // 现在在 sheet 内部显示进度条和导入中禁用操作按钮，导入完成后弹 alert 再 dismiss。
                if importService.isImporting {
                    VStack(spacing: 8) {
                        ProgressView(value: importService.importProgress)
                        Text(String(format: NSLocalizedString("正在导入…%.0f%%", comment: "Import progress"),
                                    importService.importProgress * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack {
                    Button(NSLocalizedString("取消", comment: "Cancel")) {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                    .disabled(importService.isImporting)

                    Spacer()

                    Button(NSLocalizedString("导入", comment: "Import")) {
                        startImport()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importService.isImporting)
                    .buttonStyle(.glassProminent)
                }
            }
            .padding()
            .alert(alertTitle, isPresented: $showResultAlert) {
                // 错误态保留 sheet 让用户重试 / 修改文本;成功 / 0 条都 dismiss。
                Button(NSLocalizedString("好", comment: "OK")) {
                    if case .error = outcome { return }
                    dismiss()
                }
            } message: {
                Text(alertMessage)
            }
        }
        .interactiveDismissDisabled(importService.isImporting)
    }

    private var alertTitle: String {
        switch outcome {
        case .error:
            return NSLocalizedString("import.alert.error.title",
                                     value: "导入失败",
                                     comment: "Import error alert title")
        case .noEntriesDetected:
            return NSLocalizedString("import.alert.empty.title",
                                     value: "未识别到日记",
                                     comment: "Import no entries alert title")
        case .finished:
            return NSLocalizedString("导入结果", comment: "Import result title")
        }
    }

    private var alertMessage: String {
        switch outcome {
        case .error(let detail):
            return detail
        case .noEntriesDetected:
            return NSLocalizedString("import.alert.empty.message",
                                     value: "没有从粘贴的内容里识别到任何日记。请检查格式后重试。",
                                     comment: "Import no entries detected message")
        case .finished(let succeeded, let failed):
            if failed == 0 {
                return String(format: NSLocalizedString("成功导入 %d 条日记。", comment: "Import succeeded"), succeeded)
            } else {
                return String(format: NSLocalizedString("成功 %d 条，失败 %d 条。", comment: "Import mixed"),
                              succeeded, failed)
            }
        }
    }

    // MARK: - Logic
    private func startImport() {
        // **不再立即 dismiss**：等导入完成（失败也算完成）再弹 alert 给用户看数字，然后 dismiss。
        // 三种结束态:解析抛错 / 解析返回 0 条 / 正常完成 —— 走不同 alert 文案。
        Task {
            do {
                let result = try await importService.importEntries(from: pastedText, context: viewContext)
                if result.succeeded == 0 && result.failed == 0 {
                    outcome = .noEntriesDetected
                } else {
                    outcome = .finished(succeeded: result.succeeded, failed: result.failed)
                    resultSucceeded = result.succeeded
                    resultFailed = result.failed
                }
            } catch {
                // `DiaryImportError` / 任意上抛错误。`localizedDescription` 已在
                // `DiaryImportError.errorDescription` 里翻译过。
                outcome = .error(error.localizedDescription)
            }
            showResultAlert = true
        }
    }
}

struct DiaryImportView_Previews: PreviewProvider {
    static var previews: some View {
        DiaryImportView()
            .environmentObject(CoreDataImportService())
    }
} 