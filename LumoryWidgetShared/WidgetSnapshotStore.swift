import Foundation

/// App Group 容器内的 snapshot 文件读写。**纯文件 IO**,不挂 CoreData / WidgetKit。
///
/// - 主 App 端 `WidgetSnapshotService` 调 `write(_:)` 落盘 + `WidgetCenter.reloadTimelines(...)`。
/// - Widget extension 在 `TimelineProvider.getTimeline` 调 `read()` 拉数据。
///
/// `clear()` 写一份 empty snapshot **而不是删文件** —— widget 能稳定显示"暂无日记",
/// 而不是退回 placeholder。删了文件还要 widget 端处理 nil 分支,UX 不一致。
public enum WidgetSnapshotStore {
    /// 单测用 seam:set 一个 temp dir 让 read/write 走那里,不污染真实 App Group。
    /// production 始终保持 nil。**测试必须串行**(在 setUp 里 set / tearDown 里 nil),
    /// 见 `WidgetSnapshotTests`。
    public static var overrideURL: URL?

    /// snapshot.json 的绝对路径。读取失败时(没装 entitlement / sim 没建 App Group)
    /// 返 nil,read/write 走 nil-safe 分支。
    public static func snapshotURL() -> URL? {
        if let override = overrideURL { return override }
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            return nil
        }
        return container.appendingPathComponent(AppGroup.snapshotRelativePath)
    }

    public static func read() -> WidgetSnapshot? {
        guard let url = snapshotURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snap = try jsonDecoder.decode(WidgetSnapshot.self, from: data)
            // 当前 schema = V2。其他版本(V1 旧 displayText 契约 / 中间带 recentDays 形态)
            // 一律拒收,让调用方走 empty 兜底;主 App 下次 refresh 会写入新格式覆盖,self-heal。
            guard snap.schemaVersion == 2 else { return nil }
            return snap
        } catch {
            return nil
        }
    }

    public static func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = snapshotURL() else {
            throw NSError(
                domain: "Lumory.WidgetSnapshotStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"]
            )
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try jsonEncoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        // 把文件 + 父目录都标 isExcludedFromBackup —— snapshot 是可再生数据,
        // 不进 iCloud / iTunes 备份,降存储用量、避免老快照跨设备复活。
        excludeFromBackup(url)
        excludeFromBackup(dir)
    }

    /// 用 empty snapshot 覆盖,**不**删文件。给"删除所有日记"等批量操作用。
    public static func clear() {
        do {
            try write(.empty())
        } catch {
            // 写不进去就尽量删,避免残留旧数据。
            if let url = snapshotURL() {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
