//
//  AsyncPhotoThumbnail.swift
//  Lumory
//
//  把"磁盘读一张缩略图"和 body 解耦:body 只声明有一个缩略图要显示,
//  真正的 `Data(contentsOf:)` 在 `.task` 里跑。原来直接在 body 里做 I/O,
//  播放进度 30fps 会让主线程重复命中磁盘读取。
//
//  2026-05-16 从 `DiaryDetailView.swift` 顶 file-local `private struct` 抽出独立
//  view 文件(visibility 从 file-private 提到 internal,让 `+Display.swift` extension
//  能跨文件访问)。当前唯一 caller 是 `DiaryDetailView+Display.photoThumbnail`。
//

import SwiftUI

struct AsyncPhotoThumbnail: View {
    let fileName: String
    let index: Int
    let onTap: (Int) -> Void
    @State private var thumbnailImage: ThumbnailImageDecoder.PlatformImage?

    var body: some View {
        Group {
            if let thumbnailImage {
                #if os(iOS)
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                #elseif canImport(AppKit)
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 130, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: LumoryCornerRadius.card, style: .continuous))
        // P1-Dark-5 用 .primary.opacity 而不是 .black.opacity — 暗色下 .primary 是白色,
        // 阴影成"白光"显示在暗背景上,符合 OLED 暗色 lift effect 直觉;.black.opacity 在暗背景零效果。
        .shadow(color: Color.primary.opacity(0.15), radius: 6, y: 2)
        .onTapGesture { onTap(index) }
        .task(id: fileName) {
            if thumbnailImage == nil {
                let image = await Task.detached(priority: .utility) { () -> ThumbnailImageDecoder.PlatformImage? in
                    guard let data = DiaryEntry.loadImageData(fileName: fileName) else { return nil }
                    return ThumbnailImageDecoder.decode(data: data, maxPixelSize: 390)
                }.value
                await MainActor.run { self.thumbnailImage = image }
            }
        }
    }
}
