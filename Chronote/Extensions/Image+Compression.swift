import Foundation
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
}
#endif
