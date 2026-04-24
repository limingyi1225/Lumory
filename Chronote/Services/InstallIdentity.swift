import Foundation
#if canImport(Security)
import Security
#endif

/// Per-install 唯一标识。首次启动生成 UUID 存入 iOS Keychain,后续复用。
/// 用途:后端 rate limit 的 keyGenerator;per-install 限额比 per-IP 更公平(NAT/CGNAT 下
/// 同一出口 IP 的多个用户不会互相挤)。
enum InstallIdentity {
    private static let service = "com.Mingyi.Lumory.installId"
    private static let account = "installId"

    /// 进程内懒加载 + 一次性缓存。Keychain 读取 ~ms 级别但不是 0,避免每次请求都打 Keychain。
    static let current: String = load()

    private static func load() -> String {
        if let existing = readFromKeychain() { return existing }
        let new = UUID().uuidString
        writeToKeychain(new)
        return new
    }

    private static func readFromKeychain() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if !os(macOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func writeToKeychain(_ value: String) {
        let data = Data(value.utf8)
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        #if !os(macOS)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
