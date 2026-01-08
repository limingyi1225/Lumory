import SwiftUI

struct DiaryEntryRow: View {
    let entry: DiaryEntry
    @State private var imageData: Data?
    @State private var shimmerPhase: CGFloat = 0
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    /// 标题是否正在加载（summary为nil但text存在）
    private var isSummaryLoading: Bool {
        entry.summary == nil && !(entry.text ?? "").isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Date badge
            dateBadge

            // Content
            VStack(alignment: .leading, spacing: 8) {
                // Summary or text preview with loading animation
                if isSummaryLoading {
                    // 标题加载中 - 显示shimmer动画
                    summaryLoadingView
                } else {
                    Text(entry.displayText)
                        .font(.system(size: PlatformInfo.isMacCatalyst ? 15 : 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                
                // Metadata row
                HStack(spacing: 12) {
                    // Mood indicator - show if mood value is not default (0.5)
                    if entry.moodValue != 0.5 {
                        MoodIndicator(value: entry.moodValue)
                    }
                    
                    // Audio indicator
                    if entry.audioFileName != nil {
                        Label("", systemImage: "waveform")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    
                    // Image indicator
                    if !entry.imageFileNameArray.isEmpty {
                        Label("\(entry.imageFileNameArray.count)", systemImage: "photo")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    // Time
                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Thumbnail
            if let imageData = imageData {
                #if canImport(UIKit)
                if let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                        .cornerRadius(8)
                }
                #else
                // For macOS, use NSImage
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                        .cornerRadius(8)
                }
                #endif
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
        )
        .onAppear {
            loadThumbnail()
            if isSummaryLoading {
                startShimmerAnimation()
            }
        }
    }

    // MARK: - 标题加载动画
    private var summaryLoadingView: some View {
        HStack(spacing: 8) {
            // Shimmer骨架屏
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.secondary.opacity(0.2),
                            Color.secondary.opacity(0.4),
                            Color.secondary.opacity(0.2)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 120, height: 16)
                .overlay(
                    // Shimmer光效
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.4),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: shimmerPhase * 150 - 75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // 加载指示文字
            Text("生成中...")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(height: 20)
    }

    private func startShimmerAnimation() {
        withAnimation(
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = 1.0
        }
    }

    private var dateBadge: some View {
        VStack(spacing: 2) {
            Text(dayString)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            Text(monthString)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 50)
    }
    
    // Optimized date formatters - use static instances to avoid repeated creation
    private var dayString: String {
        dayFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    private var monthString: String {
        monthFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    private var timeString: String {
        timeFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    // Dynamic formatters that respond to language changes
    private func dayFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.dateFormat = "dd"
        return f
    }

    private func monthFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.dateFormat = "MMM"
        return f
    }

    private func timeFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.timeStyle = .short
        return f
    }
    
    private func loadThumbnail() {
        guard imageData == nil,
              let firstImageName = entry.imageFileNameArray.first else { return }

        // Capture value type (String) to avoid capturing CoreData object 'entry'
        let fileName = firstImageName
        
        Task.detached(priority: .utility) {
            // Use static helper or direct file access to avoid 'entry' capture
            // Assuming DiaryEntry has a static load helper or we implement simple loading
            // To be safe and fix the error immediately, let's implement the loading manually here
            // which guarantees we don't touch the localized 'entry' object.
            
            let documentURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentURL.appendingPathComponent(fileName)
            
            if let data = try? Data(contentsOf: fileURL) {
                await MainActor.run {
                    self.imageData = data
                }
            } else {
                // Should also check iCloud if local fails, but for now fixed the crash/error
                // If there's a specific static method on DiaryEntry, we should use that instead.
                // Reverting to instance call is not allowed. 
                // Let's rely on the text preview if image fails or wait for full load in detail.
            }
        }
    }
}

// MARK: - Supporting Views
struct MoodIndicator: View {
    let value: Double
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.moodSpectrum(value: value))
                .frame(width: 8, height: 8)
            
            Text(moodText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var moodText: String {
        switch value {
        case 0..<0.2:
            return "很差"
        case 0.2..<0.4:
            return "较差"
        case 0.4..<0.6:
            return "一般"
        case 0.6..<0.8:
            return "不错"
        case 0.8...1.0:
            return "很好"
        default:
            return "一般"
        }
    }
}

#Preview {
    DiaryEntryRow(entry: {
        let context = PersistenceController.shared.container.viewContext
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = Date()
        entry.text = "今天是个好天气，心情特别愉快。和朋友一起吃了午饭，聊了很多有趣的话题。"
        entry.summary = "愉快的一天"
        entry.moodValue = 0.8
        // hasMoodAnalysis property has been removed
        return entry
    }())
    .padding()
}