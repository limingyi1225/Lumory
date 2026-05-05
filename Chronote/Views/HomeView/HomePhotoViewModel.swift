import SwiftUI
import Foundation
import PhotosUI

/// HomeView 的"图片选择 / 压缩"相关状态合成一层 VM。
///
/// 迁移原则: 字段初值、顺序、可见性 1:1 搬过来,不重命名。压缩任务(`loadPhotosWithCompression`)
/// 的实现仍在 HomeView 里原位跑——它需要访问 View 身上的 `MainActor.run` 闭包写这些字段,
/// VM 作为单一存储点,任务里直接写 `photoVM.selectedImageItems` / `photoVM.selectedPhotos`。
@available(iOS 17.0, *)
@Observable
final class HomePhotoViewModel {
    struct SelectedImage: Identifiable, Equatable {
        let id: UUID
        let data: Data

        init(id: UUID = UUID(), data: Data) {
            self.id = id
            self.data = data
        }
    }

    /// PhotosPicker 选到的原始 item 列表。和 `selectedImageItems` **严格等长**,删除时同步剪枝。
    var selectedPhotos: [PhotosPickerItem] = []

    /// 用 Button + .photosPicker(isPresented:) 弹 sheet,而不是 PhotosPicker 直接当
    /// button 用 —— 后者在 HStack 里 hit area 会和隔壁按钮串,导致点照片触发录音。
    var photosPickerPresented: Bool = false

    /// 上一次的 photo 压缩任务,选择变化时取消,防止旧任务回来覆盖新结果(F1 race fix)。
    var photoLoadTask: Task<Void, Never>?

    /// 压缩完成后会把 `selectedPhotos` 剪枝到成功项;这次程序性写回不应再次触发压缩。
    var suppressNextPhotoSelectionReload = false

    /// 压缩成功后的 JPEG Data + 稳定 UI identity,和 selectedPhotos 严格等长、同序。
    var selectedImageItems: [SelectedImage] = []

    /// 兼容发送 / 落库路径的 Data 视图。UI 列表不要用它作 identity。
    var selectedImages: [Data] {
        get { selectedImageItems.map(\.data) }
        set { selectedImageItems = newValue.map { SelectedImage(data: $0) } }
    }

    /// 上一次压缩中失败的张数;非 0 时 HomeView 显示 inline toast 让用户知道有多少张被吞了。
    /// 用户主动关掉 / 重新选 → 清零。
    var compressionFailureCount: Int = 0
}
