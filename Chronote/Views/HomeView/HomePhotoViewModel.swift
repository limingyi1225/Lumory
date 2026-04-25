import SwiftUI
import Foundation
import PhotosUI

/// HomeView 的"图片选择 / 压缩"相关状态合成一层 VM。
///
/// 迁移原则: 字段初值、顺序、可见性 1:1 搬过来,不重命名。压缩任务(`loadPhotosWithCompression`)
/// 的实现仍在 HomeView 里原位跑——它需要访问 View 身上的 `MainActor.run` 闭包写这两个字段,
/// VM 作为单一存储点,任务里直接写 `photoVM.selectedImages` / `photoVM.selectedPhotos`。
@available(iOS 17.0, *)
@Observable
final class HomePhotoViewModel {
    /// PhotosPicker 选到的原始 item 列表。和 `selectedImages` **严格等长**,删除时同步剪枝。
    var selectedPhotos: [PhotosPickerItem] = []

    /// 用 Button + .photosPicker(isPresented:) 弹 sheet,而不是 PhotosPicker 直接当
    /// button 用 —— 后者在 HStack 里 hit area 会和隔壁按钮串,导致点照片触发录音。
    var photosPickerPresented: Bool = false

    /// 上一次的 photo 压缩任务,选择变化时取消,防止旧任务回来覆盖新结果(F1 race fix)。
    var photoLoadTask: Task<Void, Never>?

    /// 压缩成功后的 JPEG Data,和 selectedPhotos 严格等长、同序。
    var selectedImages: [Data] = []
}
