//
//  ImageViewerView.swift
//  Lumory
//
//  Created by Assistant on 6/6/25.
//

import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#endif

struct ImageViewerView: View {
    let images: [Data]
    @Binding var selectedIndex: Int
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    /// 下滑关闭手势的整张 viewer 偏移。scale==1 时跟随手指,松手 height>100 dismiss、否则 spring 回 0。
    @State private var dismissDragOffset: CGSize = .zero
    /// 标记当前是否在跑下滑关闭手势 — 让 onEnded 时区分"跨 page 横滑"vs"竖向 dismiss"。
    @State private var isDismissDragging: Bool = false
    @Environment(\.dismiss) private var dismiss

    /// 距离阈值,松手高度超过这个就 dismiss
    private static let dismissThreshold: CGFloat = 100

    var body: some View {
        ZStack {
            // Background — 下滑过程逐渐透明,viewer 跟着 offset 走。
            Color.black
                .ignoresSafeArea()
                .opacity(backgroundOpacity)
                .onTapGesture {
                    isPresented = false
                }

            // Main content — lazy decode each page so we don't balloon all images at once
            TabView(selection: $selectedIndex) {
                ForEach(images.indices, id: \.self) { index in
                    ImageViewerPage(
                        data: images[index],
                        isVisible: index == selectedIndex,
                        scale: $scale,
                        offset: $offset,
                        dragOffset: $dragOffset
                    )
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString("图片 %1$d / %2$d", comment: "Image viewer position label"),
                        index + 1,
                        images.count
                    )))
                    .tag(index)
                }
            }
            .accessibilityIdentifier("imageViewer.pager")
            #if os(iOS)
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
            #else
            .tabViewStyle(.automatic)
            #endif

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        #if canImport(UIKit)
                        HapticManager.shared.impact(.light)
                        #endif
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.3))
                            )
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text(NSLocalizedString("关闭", comment: "Image viewer close button")))
                    .padding()
                }
                Spacer()
            }

            // Image counter
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(selectedIndex + 1) / \(images.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.3))
                        )
                        .padding()
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: selectedIndex) { _, _ in
            // Reset zoom when changing images
            withAnimation(.spring()) {
                scale = 1
                offset = .zero
                dragOffset = .zero
            }
        }
        .onChange(of: scale) { _, newScale in
            // **scale 切走 1 时清 dismiss drag 状态** — gesture inclusion 会随 scale 重新挂,
            // 旧 in-flight drag 的 onEnded 可能不 fire,留非 0 offset。这里兜底 reset。
            if newScale != 1, dismissDragOffset != .zero {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    dismissDragOffset = .zero
                }
                isDismissDragging = false
            }
        }
        // **下滑关闭** — 跟 Apple Photos / iMessage 的肌肉记忆一致。仅 scale == 1 时激活;
        // scale > 1 时 inner ImageViewerPage 的 dragGesture 拦截走 pan,不会触发到这里。
        .offset(y: dismissDragOffset.height)
        .simultaneousGesture(dismissDragGesture, including: scale == 1 ? .all : .subviews)
    }

    private var backgroundOpacity: Double {
        // 0.95 起始,height 0~200 区间线性减到 0.5,给"在 dismiss"的反馈但不至于看不到图。
        let h = abs(dismissDragOffset.height)
        let progress = min(h / 200, 1)
        return 0.95 - 0.45 * progress
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // 只接竖向 — 水平由 TabView 自己消费翻 page。第一次 onChanged 拍板方向后,
                // 后续都跟 isDismissDragging 走避免抖动。
                if !isDismissDragging {
                    if abs(value.translation.height) > abs(value.translation.width),
                       value.translation.height > 0 {
                        isDismissDragging = true
                    } else {
                        return
                    }
                }
                dismissDragOffset = CGSize(width: 0, height: max(0, value.translation.height))
            }
            .onEnded { value in
                guard isDismissDragging else {
                    dismissDragOffset = .zero
                    return
                }
                isDismissDragging = false
                if value.translation.height > Self.dismissThreshold {
                    #if canImport(UIKit)
                    HapticManager.shared.impact(.light)
                    #endif
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dismissDragOffset = .zero
                    }
                }
            }
    }
}

// MARK: - Lazy page

/// One page inside the TabView. Decodes a downsampled image only when visible
/// and releases it when scrolled offscreen — keeps memory bounded for albums of
/// several originals (TabView would otherwise hold every UIImage simultaneously).
private struct ImageViewerPage: View {
    let data: Data
    let isVisible: Bool
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    @Binding var dragOffset: CGSize

    #if os(iOS)
    @State private var image: UIImage?
    #else
    @State private var image: NSImage?
    #endif
    @State private var didFailDecode = false
    @State private var decodeTask: Task<Void, Never>?
    @State private var magnificationBaseScale: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                        .gesture(magnificationGesture)
                        .simultaneousGesture(dragGesture)
                        .onTapGesture(count: 2) { handleDoubleTap() }
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                        .gesture(magnificationGesture)
                        .simultaneousGesture(dragGesture)
                        .onTapGesture(count: 2) { handleDoubleTap() }
                    #endif
                } else if didFailDecode {
                    fallbackView
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    // 加载期不再用 `Color.clear` 等成黑屏 —— 给 ProgressView 让用户看到"在加载",
                    // 大图(iCloud 拉过来未在本地或 12MP 慢解码)有几百 ms 等待。
                    loadingView
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .onAppear {
                loadImage(viewportWidth: geometry.size.width)
            }
            .onDisappear {
                // Cancel any in-flight decode so a stale result can't write back
                // into @State after we've scrolled off-screen.
                decodeTask?.cancel()
                decodeTask = nil
                // Release neighbor pages so memory stays bounded.
                image = nil
            }
            .onChange(of: isVisible) { _, nowVisible in
                if nowVisible, image == nil {
                    loadImage(viewportWidth: geometry.size.width)
                } else if !nowVisible {
                    // Page swiped away while still in TabView's window — kill the
                    // decode early so fast swipes don't pile up N concurrent jobs.
                    decodeTask?.cancel()
                    decodeTask = nil
                }
            }
        }
    }

    // MARK: Gestures (preserved verbatim from original implementation)

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnificationBaseScale ?? scale
                if magnificationBaseScale == nil {
                    magnificationBaseScale = base
                }
                scale = max(1, min(base * value.magnification, 3))
            }
            .onEnded { _ in
                withAnimation(.spring()) {
                    scale = max(1, min(scale, 3))
                    if scale == 1 {
                        offset = .zero
                    }
                }
                magnificationBaseScale = nil
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    dragOffset = value.translation
                }
            }
            .onEnded { _ in
                withAnimation(.spring()) {
                    offset.width += dragOffset.width
                    offset.height += dragOffset.height
                    dragOffset = .zero

                    // Reset if scale is 1
                    if scale == 1 {
                        offset = .zero
                    }
                }
            }
    }

    private func handleDoubleTap() {
        #if canImport(UIKit)
        HapticManager.shared.impact(.light)
        #endif
        withAnimation(.spring()) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                scale = 2
            }
        }
    }

    // MARK: Fallback / Loading

    private var fallbackView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white.opacity(0.6))
            Text(NSLocalizedString("无法加载图片", comment: "Image decode failed message"))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var loadingView: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white.opacity(0.85))
            .scaleEffect(1.2)
    }

    // MARK: Decode

    private func loadImage(viewportWidth: CGFloat) {
        // `data` is `Data` (value semantics) on the View struct, so capturing it
        // for the detached task is safe — no shared mutable reference to worry about.
        let payload = data
        // Aim for ~2x viewport width in pixels — sharp on retina without keeping
        // the full original bitmap (a 12MP shot would otherwise cost ~48MB decoded).
        let targetWidth = max(viewportWidth, 1)

        // Cancel any prior in-flight decode before reassigning. Without this,
        // fast swipes pile up N concurrent CGImageSourceCreateThumbnailAtIndex
        // jobs and old completions race back to write @State after we've moved on.
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) {
            #if os(iOS)
            // 固定 3.0 —— iPhone Pro 系列原生 scale,iOS 26 起 UIScreen.main 已 deprecated。
            // 这里只是缩略图解码的目标像素,不参与最终渲染;略微 over-downsample 在 2x 设备
            // 也仍然 sharp（targetWidth 已经是 viewport 宽,*2 留 retina headroom）。
            let scaleFactor: CGFloat = 3.0
            let maxPixel = targetWidth * 2 * scaleFactor
            let decoded = Self.downsample(data: payload, maxPixelSize: maxPixel)
            // Cheap check before hopping back to main — if the user has already
            // swiped past us, drop the decoded bitmap on the floor.
            if Task.isCancelled { return }
            await MainActor.run {
                // Re-check after the actor hop: cancellation could have landed
                // while we were waiting for main.
                guard !Task.isCancelled else { return }
                if let decoded {
                    self.image = decoded
                    self.didFailDecode = false
                } else {
                    self.image = nil
                    self.didFailDecode = true
                }
            }
            #else
            let decoded = NSImage(data: payload)
            if Task.isCancelled { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let decoded {
                    self.image = decoded
                    self.didFailDecode = false
                } else {
                    self.image = nil
                    self.didFailDecode = true
                }
            }
            #endif
        }
    }

    #if os(iOS)
    /// Downsample using ImageIO so we never realize the full-resolution bitmap
    /// in memory — the single biggest memory win for the photo viewer.
    /// `nonisolated`：纯 ImageIO/CGImageSource 调用,不触 main-actor state,
    /// 让 `Task.detached` 能直接调用而不需要 hop 回 main。
    nonisolated static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
    #endif
}

// Preview
#Preview {
    ImageViewerView(
        images: [],
        selectedIndex: .constant(0),
        isPresented: .constant(true)
    )
}
