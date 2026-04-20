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
            .alert(NSLocalizedString("导入结果", comment: "Import result title"), isPresented: $showResultAlert) {
                Button(NSLocalizedString("好", comment: "OK")) { dismiss() }
            } message: {
                if resultFailed == 0 {
                    Text(String(format: NSLocalizedString("成功导入 %d 条日记。", comment: "Import succeeded"), resultSucceeded))
                } else {
                    Text(String(format: NSLocalizedString("成功 %d 条，失败 %d 条。", comment: "Import mixed"),
                                resultSucceeded, resultFailed))
                }
            }
        }
        .interactiveDismissDisabled(importService.isImporting)
    }

    // MARK: - Logic
    private func startImport() {
        // **不再立即 dismiss**：等导入完成（失败也算完成）再弹 alert 给用户看数字，然后 dismiss。
        Task {
            let result = await importService.importEntries(from: pastedText, context: viewContext)
            resultSucceeded = result.succeeded
            resultFailed = result.failed
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