import Foundation
import SwiftUI

// MARK: - Bundle Extension for Localization

extension Bundle {
    static var appLanguageBundle: Bundle {
        let appLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? Locale.current.identifier
        
        // Map the stored language to the correct bundle identifier
        let languageCode: String
        if appLanguage.hasPrefix("zh") || appLanguage == "zh-Hans" {
            languageCode = "zh-Hans"
        } else {
            languageCode = "en"
        }
        
        // Get the bundle for the selected language
        guard let bundlePath = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath) else {
            return Bundle.main
        }
        
        return bundle
    }
}

// MARK: - Override NSLocalizedString

public func NSLocalizedString(
    _ key: String,
    tableName: String? = nil,
    bundle: Bundle = Bundle.main,
    value: String = "",
    comment: String
) -> String {
    Bundle.appLanguageBundle.localizedString(forKey: key, value: value, table: tableName)
}
