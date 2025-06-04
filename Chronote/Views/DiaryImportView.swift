import SwiftUI
import CoreData

struct DiaryImportView: View {
    @EnvironmentObject var importService: CoreDataImportService
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText: String = ""
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    // 日期解析失败提示暂不处理

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // 标题
                Text(NSLocalizedString("导入日记", comment: "Import diaries title"))
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // 说明文字
                Text(NSLocalizedString("将你的日记粘贴到下面，支持多篇日记连贴。", comment: "Import instruction"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // 文本编辑框
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

                Spacer()

                // 操作按钮
                HStack {
                    Button(NSLocalizedString("取消", comment: "Cancel")) {
                        dismiss()
                    }
                    .foregroundColor(.primary)

                    Spacer()

                    Button(NSLocalizedString("导入", comment: "Import")) {
                        startImport()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        // .alert("无法检测到日期", isPresented: $showMissingDateAlert) { /* 暂时不处理 */ }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Logic
    private func startImport() {
        // 立即关闭视图并开始后台导入
        dismiss()
        Task { await importService.importEntries(from: pastedText, context: viewContext) }
    }
}

struct DiaryImportView_Previews: PreviewProvider {
    static var previews: some View {
        DiaryImportView()
            .environmentObject(CoreDataImportService())
    }
} 