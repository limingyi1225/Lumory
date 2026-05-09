import SwiftUI

// MARK: - Input photo thumbnail (lazy decode + cache)
//
// 抽出独立子视图避免父视图(HomeView)body 重 eval 时反复 `UIImage(data:)` 解码 9 张图。
// 之前每输入一个字符就触发 9 次解码,选完照片后输入卡卡得没法用。
//
// 内部用 .task(id: dataID) 把 UIImage 解码挪到 Task.detached 后台,完成后存到 @State。
// data 变了(新一组照片)才重新解码。

struct InputPhotoThumbnail: View {
    let data: Data
    let dataID: UUID
    let onRemove: () -> Void

    #if canImport(UIKit)
    @State private var decoded: UIImage?
    #else
    @State private var decoded: NSImage?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let decoded {
                    #if canImport(UIKit)
                    Image(uiImage: decoded)
                        .resizable()
                        .scaledToFill()
                    #else
                    Image(nsImage: decoded)
                        .resizable()
                        .scaledToFill()
                    #endif
                } else {
                    Color.secondary.opacity(0.10)
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    // hit area 32×32 圆形 — 视觉 fill 仍 20pt,但实际可 tap 区扩大到接近 HIG 44pt 推荐
                    // (9 张缩略图横排,误触常见)。
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(4)
        }
        .task(id: dataID) {
            // detached → 解码不占主线程,选 9 张图后输入框立刻能用,缩略图陆续浮上来。
            let bytes = data
            let image = await Task.detached(priority: .userInitiated) { () -> ThumbnailImageDecoder.PlatformImage? in
                ThumbnailImageDecoder.decode(data: bytes, maxPixelSize: 240)
            }.value
            await MainActor.run { self.decoded = image }
        }
    }
}
