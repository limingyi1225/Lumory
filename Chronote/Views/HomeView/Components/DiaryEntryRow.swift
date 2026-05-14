import SwiftUI

struct DiaryEntryRow: View {
    // **P1 fix (2026-05-13 superreview round 2)**:与同期 `HomeTimelineCard.entry` 写法对齐。
    // AI summary writeback(`EntryCreationService.performAIWriteback`)异步写回
    // `entry.summary` 时,`@ObservedObject` 让 SwiftUI 稳定收到 NSManagedObject 的 willChange,
    // 触发 row 重建把 shimmer 换成真摘要。原 `let entry: DiaryEntry` + `FetchedResults publish`
    // 在某些场景下不够稳(HomeTimelineCard:11 注释已 callout 同款踩坑)。
    @ObservedObject var entry: DiaryEntry
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
                            // F9 — entry.summary 字号语义化(Dynamic Type 友好,跟 4 处 callsite 统一)
                            Text(entry.displayText)
                                .font(.callout.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        // Metadata row
                        HStack(spacing: 12) {
                            // MoodIndicator(色点 + "不错" / "较差" 文字)已删除 (2026-05-12) —
                            // 用户反馈跟整 row 的 liquidGlassCard mood tint 是同一信息双重表达。

                            // 录音标识 — 极简 mic icon,没数字 label。
                            // wave17 superreview P2-10 加回:大 waveform 太杂被砍后,Insights row 完全
                            // 看不出哪条有录音。换成更小的 mic.fill,占位仅 caption2 不抢内容主体。
                            if let audio = entry.audioFileName, !audio.isEmpty {
                                Image(systemName: "mic.fill")
                                    .font(.caption)
                                    // 改用 accentColor(App 主色调浅蓝)—— 原 .orange 跟整体浅蓝色系
                                    // 冲突,小 metadata 图标用主色调更协调(2026-05-14 用户反馈)。
                                    .foregroundColor(.accentColor)
                                    .accessibilityLabel(NSLocalizedString("含录音", comment: "Audio attachment indicator"))
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
        // P1-Home-8 整张 row 给 mood gradient 淡背景 — entry.moodColor tint 0.10。
        // 2026-05-12:MoodIndicator(色点 + 文字 label)删除后,row mood 信号只剩这层 tint,
        // 从 0.06 → 0.10 让 mood 仍可一眼分辨;低于 0.15 仍不抢内容主体。
        .liquidGlassCard(
            cornerRadius: LumoryCornerRadius.card,
            tint: Color.moodSpectrum(value: entry.moodValue),
            tintStrength: 0.10,
            interactive: true
        )
        .onAppear {
            if isSummaryLoading {
                startShimmerAnimation()
            }
        }
        // **P1 fix (2026-05-13 superreview)**:summary writeback 后 isSummaryLoading 翻 false,
        // 但 repeatForever 动画上下文仍持有 shimmerPhase;LazyVStack reuse 时 onAppear 未必再
        // fire。显式 onChange 启停,reset 走 zero-duration withAnimation 打断 repeat 链。
        .onChange(of: isSummaryLoading) { _, loading in
            if loading {
                startShimmerAnimation()
            } else {
                stopShimmerAnimation()
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

    private func stopShimmerAnimation() {
        withAnimation(.linear(duration: 0)) {
            shimmerPhase = 0
        }
    }

    private var dateBadge: some View {
        VStack(spacing: 2) {
            Text(dayString)
                .font(LumoryFonts.entryDateBadge)
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

// MoodIndicator struct(色点 + 文字 label)已删除(2026-05-12):整 row mood tint 已表达,
// 不再需要内部小色点。

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
