import Foundation

// MARK: - Bundle Extension for Localization

/// 主 App 与 widget extension 共享的本地化路由。
///
/// 行为:从 **App Group UserDefaults** 读 `appLanguage`(用户在主 App Settings 选的偏好),
/// 找不到时回退主 App `UserDefaults.standard`(老用户的值还没被迁移到 App Group 的过渡窗口),
/// 仍找不到则回退系统 locale。这套读取链让 widget 显示的语言跟主 App 一致 ——
/// 否则 widget 走系统 locale,主 App 选中文 + 设备英文用户会看到 widget 是英文。
///
/// 写入由 `@AppStorage("appLanguage", store: AppGroup.userDefaults)` 处理(主 App 6 处都改用
/// App Group store),自动同步到 widget 端。
extension Bundle {
    static var appLanguageBundle: Bundle {
        let appLanguage =
            AppGroup.userDefaults.string(forKey: "appLanguage")
            ?? UserDefaults.standard.string(forKey: "appLanguage")
            ?? Locale.current.identifier

        // Map the stored language to the correct bundle identifier
        let languageCode: String
        if appLanguage.hasPrefix("zh") || appLanguage == "zh-Hans" {
            languageCode = "zh-Hans"
        } else {
            languageCode = "en"
        }

        // Get the bundle for the selected language。
        // **`Bundle.main`** 在主 App 是 `Lumory.app`,在 widget extension 是 `LumoryWidgets.appex`。
        // 两个 bundle 各自有 `en.lproj` / `zh-Hans.lproj`,各自的 strings 表。
        guard let bundlePath = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath) else {
            return Bundle.main
        }

        return bundle
    }
}

// MARK: - Override NSLocalizedString

/// **全局函数 override**,屏蔽掉 Foundation 自带的 NSLocalizedString。两个 target 都编进这一份,
/// 所以主 App / widget 调 `NSLocalizedString(...)` 走的都是这条 → 共享语言偏好。
public func NSLocalizedString(
    _ key: String,
    tableName: String? = nil,
    bundle: Bundle = Bundle.main,
    value: String = "",
    comment: String
) -> String {
    Bundle.appLanguageBundle.localizedString(forKey: key, value: value, table: tableName)
}
