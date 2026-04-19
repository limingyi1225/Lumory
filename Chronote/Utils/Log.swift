import Foundation
import os

// MARK: - Logging
//
// 双层策略：
// 1. `print(...)` 在 Release 下被下面的全局 no-op 接管 → 旧代码零改动地静默。
// 2. 新代码请用 `Log.info(...)` / `Log.error(...)`：它走 `os.Logger`，
//    DEBUG 会在 Xcode Console 输出，Release 会被系统 log 捕获，
//    可用 Console.app 按 subsystem (`Mingyi.Lumory`) 过滤查看。
//
// 分类 (`Log.Category`) 只是 OSLog category 字段，用于在 Console.app 里分流。

enum Log {
    enum Category: String {
        case general
        case ai
        case network
        case persistence
        case sync
        case audio
        case ui
        case migration
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Mingyi.Lumory"

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: [
            Category.general, .ai, .network, .persistence,
            .sync, .audio, .ui, .migration
        ].map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    private static func logger(_ category: Category) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    // 文本消息一律 `.private` —— 日记内容、AI 响应、摘要、转录等经常流到 Log.*，
    // 用 `.public` 会被 Console.app / sysdiagnose 明文捕获，对日记 App 是灾难。
    // 只让 file / line（源码位置元数据）保持 .public，便于定位。
    // message() 作为 @autoclosure 保持原样，OSLog 看到 log level 没开启会跳过求值。

    static func debug(
        _ message: @autoclosure () -> String,
        category: Category = .general,
        file: String = #fileID,
        line: Int = #line
    ) {
        let text = message()
        logger(category).debug("[\(file, privacy: .public):\(line, privacy: .public)] \(text, privacy: .private)")
    }

    static func info(
        _ message: @autoclosure () -> String,
        category: Category = .general,
        file: String = #fileID,
        line: Int = #line
    ) {
        let text = message()
        logger(category).info("[\(file, privacy: .public):\(line, privacy: .public)] \(text, privacy: .private)")
    }

    static func warning(
        _ message: @autoclosure () -> String,
        category: Category = .general,
        file: String = #fileID,
        line: Int = #line
    ) {
        let text = message()
        logger(category).warning("[\(file, privacy: .public):\(line, privacy: .public)] \(text, privacy: .private)")
    }

    static func error(
        _ message: @autoclosure () -> String,
        category: Category = .general,
        file: String = #fileID,
        line: Int = #line
    ) {
        let text = message()
        logger(category).error("[\(file, privacy: .public):\(line, privacy: .public)] \(text, privacy: .private)")
    }

    static func error(
        _ error: Error,
        category: Category = .general,
        file: String = #fileID,
        line: Int = #line
    ) {
        let text = String(describing: error)
        logger(category).error("[\(file, privacy: .public):\(line, privacy: .public)] \(text, privacy: .private)")
    }
}

// MARK: - Release silencer for legacy `print(...)` call sites.
// 历史代码大量使用 `print(...)`，Release 下全部消音，避免潜在信息泄漏和 I/O 成本。
// 新代码请迁移到 `Log.*`。
#if !DEBUG
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif
