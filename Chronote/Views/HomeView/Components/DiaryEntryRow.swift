import SwiftUI

struct DiaryEntryRow: View {
    let entry: DiaryEntry
    @State private var thumbnailImage: ThumbnailImageDecoder.PlatformImage?
    @State private var loadedThumbnailFileName: String?
    @State private var shimmerPhase: CGFloat = 0
    // 默认值必须跟随系统 locale，否则首次启动前强制英语与其他读 `appLanguage` 的组件不一致。
    @AppStorage("appLanguage", store: AppGroup.userDefaults) private var appLanguage: String = DiaryEntryRow.defaultAppLanguage

    private static var defaultAppLanguage: String {
        Locale.current.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    /// 标题是否正在加载（summary为nil但text存在）
    private var isSummaryLoading: Bool {
        guard entry.managedObjectContext != nil, !entry.isDeleted else { return false }
        return entry.summary == nil && !(entry.text ?? "").isEmpty
    }

    private var hasAnalyzedMood: Bool {
        abs(entry.moodValue - 0.5) > 0.0001 && abs(entry.moodValue) > 0.0001
    }

    var body: some View {
        Group {
            if entry.managedObjectContext == nil || entry.isDeleted {
                EmptyView()
            } else {
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
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        // Metadata row
                        HStack(spacing: 12) {
                            // Mood indicator — 0.5 是 neutral sentinel（当前默认值），0.0 是老版本的
                            // Core Data 默认值（升级用户 / CloudKit 老记录可能带 0.0），两者都视作
                            // "未分析"隐藏掉 indicator。AI 真实返回值落在开区间 (0,1)，精确命中
                            // 0.0 或 0.5 的概率极低，作 sentinel 够用。浮点比较用 tolerance 防御桥接误差。
                            if hasAnalyzedMood {
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
                    if let thumbnailImage {
                        // P0-3 替 deprecated `.cornerRadius` → `.clipShape(... continuous)`,跟 iOS 26 大圆角统一。
                        #if canImport(UIKit)
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        #elseif canImport(AppKit)
                        Image(nsImage: thumbnailImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        #endif
                    } else if !entry.imageFileNameArray.isEmpty {
                        // 只有"这条日记确实有图片、但还在加载"的时候才显示占位；
                        // 根本没图的日记不再显示误导性的照片占位图。
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                    }
                }
            }
        }
        .padding()
        // P1-Home-8 整张 row 给 mood gradient 极淡背景 — entry.moodColor tint 0.06,
        // 让"心情色"从只在 thumbnail 旁的小色块,提升为整 row 的氛围。强度低,不抢内容主体。
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.card,
            tint: Color.moodSpectrum(value: entry.moodValue),
            tintStrength: 0.06,
            interactive: true
        )
        .onAppear {
            if isSummaryLoading {
                startShimmerAnimation()
            }
        }
        .task(id: thumbnailFileName) {
            await loadThumbnail(fileName: thumbnailFileName)
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
            Text(NSLocalizedString("status.generating", value: "生成中...", comment: "Summary-being-generated shimmer label"))
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

    // ** 共享缓存的 DateFormatter ** —— 走 `LumoryDateFormatters` 的 language-aware accessor。
    // 老实现每次 body eval 都 new 一次 DateFormatter,scroll 500 条日记时每次 diff 触发数千次
    // ICU locale 加载。共享 cache 按 (kind, language) 复用,跨 row 共享一份。
    private var dayString: String { LumoryDateFormatters.dayNumber(language: appLanguage).string(from: entry.wrappedDate) }
    private var monthString: String { LumoryDateFormatters.monthShortLocalized(language: appLanguage).string(from: entry.wrappedDate) }
    private var timeString: String { LumoryDateFormatters.timeShortLocalized(language: appLanguage).string(from: entry.wrappedDate) }

    private var thumbnailFileName: String? {
        guard entry.managedObjectContext != nil, !entry.isDeleted else { return nil }
        return entry.imageFileNameArray.first
    }

    @MainActor
    private func loadThumbnail(fileName: String?) async {
        guard let fileName else {
            thumbnailImage = nil
            loadedThumbnailFileName = nil
            return
        }
        guard loadedThumbnailFileName != fileName else { return }
        thumbnailImage = nil

        // 只捕获文件名（值类型）——不跨线程持有 managed object。
        // 静态 `loadImageData(fileName:)` 会依次查 iCloud / LumoryImages / 老位置三处。
        let image = await Task.detached(priority: .utility) { () -> ThumbnailImageDecoder.PlatformImage? in
            guard let data = DiaryEntry.loadImageData(fileName: fileName) else { return nil }
            return ThumbnailImageDecoder.decode(data: data, maxPixelSize: 120)
        }.value
        guard !Task.isCancelled else { return }
        thumbnailImage = image
        loadedThumbnailFileName = fileName
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
            return NSLocalizedString("mood.veryBad", value: "很差", comment: "Mood: very bad")
        case 0.2..<0.4:
            return NSLocalizedString("mood.bad", value: "较差", comment: "Mood: bad")
        case 0.4..<0.6:
            return NSLocalizedString("mood.neutral", value: "一般", comment: "Mood: neutral")
        case 0.6..<0.8:
            return NSLocalizedString("mood.good", value: "不错", comment: "Mood: good")
        case 0.8...1.0:
            return NSLocalizedString("mood.veryGood", value: "很好", comment: "Mood: very good")
        default:
            return NSLocalizedString("mood.neutral", value: "一般", comment: "Mood: neutral")
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
