import Foundation
import ImageIO
import AVFoundation
#if canImport(UIKit)
import UIKit

extension Data {
    /// 异步压缩图片数据
    /// - Parameters:
    ///   - maxSizeKB: 最大文件大小（KB），默认500KB
    ///   - maxDimension: 最大尺寸（宽或高），默认1024px
    /// - Returns: 压缩后的图片数据，如果失败返回nil
    func compressImage(maxSizeKB: Int = 500, maxDimension: CGFloat = 1024) async -> Data? {
        guard let image = UIImage(data: self) else { return nil }

        // 1. 调整尺寸
        let resized = image.resizeToFit(maxDimension: maxDimension)

        // 2. 压缩质量
        var compression: CGFloat = 0.7
        var imageData = resized.jpegData(compressionQuality: compression)

        // 3. 循环降低质量直到满足大小限制
        while let data = imageData, data.count > maxSizeKB * 1024 && compression > 0.3 {
            compression -= 0.1
            imageData = resized.jpegData(compressionQuality: compression)
        }

        return imageData
    }
}

extension UIImage {
    /// 等比例缩放图片以适应最大尺寸
    /// - Parameter maxDimension: 最大宽度或高度
    /// - Returns: 缩放后的图片
    func resizeToFit(maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)

        // 如果图片已经小于最大尺寸，直接返回
        if scale >= 1.0 {
            return self
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 编码为 HEIC 数据。失败返回 nil —— 调用方需要自己回退到 JPEG。
    ///
    /// 失败场景（不全是 bug）：
    ///   - CMYK / 非 RGB 色彩空间 —— `CGImageDestinationFinalize` 会返回 false
    ///   - 设备 / OS 不开 HEIC 编码器（模拟器历史上踩过）
    ///   - `cgImage` 为空（纯 CIImage-backed 的 UIImage，日记 App 不太可能出现,但要保底）
    ///
    /// 必须检查 `CGImageDestinationFinalize` 的 Bool 返回值,不检查的话
    /// `mutableData` 可能是空的,调用方把空 Data 当成 "成功但 0 字节" 写进 blob。
    func heicData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = self.cgImage else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, AVFileType.heic as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
#endif
