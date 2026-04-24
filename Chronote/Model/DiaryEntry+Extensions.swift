import SwiftUI
import CoreData

// MARK: - Core Data DiaryEntry 扩展
extension DiaryEntry {
    // Image cache - thread-safe
    // 阈值从 100MB 降到 50MB：iPad 多任务 / 前台 jetsam 阈值紧时 100MB 容易触发系统 kill。
    // 配合 ChronoteApp 里注册的 didReceiveMemoryWarning 通知，系统吃紧时还会显式调
    // clearImageCache() 立刻释放。
    private static let imageCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()
    private static let cacheQueue = DispatchQueue(label: "com.lumory.imagecache", attributes: .concurrent)
    /// 获取显示文本（用于列表展示）
    var displayText: String {
        let raw = summary ?? String((text ?? "").prefix(30)) + "..."
        // 过滤掉句号、星号和引号
        let filtered = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return filtered
    }
    
    /// 包装器属性，避免强制解包
    var wrappedText: String {
        text ?? ""
    }
    
    var wrappedDate: Date {
        date ?? Date()
    }
    
    var wrappedSummary: String? {
        summary
    }
    
    var wrappedId: UUID {
        id ?? UUID()
    }
    
    var wrappedAudioFileName: String? {
        audioFileName
    }
    
    var wrappedImageFileNames: String? {
        imageFileNames
    }
    
    /// 格式化日期用于显示
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: wrappedDate)
    }
    
    /// 心情颜色
    var moodColor: Color {
        Color.moodSpectrum(value: moodValue)
    }
    
    /// Content property (alias for text)
    var content: String? {
        text
    }
    
    /// Mood as integer (1-5)
    var mood: Int16 {
        Int16(min(max(Int(moodValue * 4 + 1), 1), 5))
    }
}

// MARK: - Themes (AI-extracted categorical tags, CSV-stored)
extension DiaryEntry {
    /// 解析 themes CSV → [String]
    var themeArray: [String] {
        guard let raw = themes, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 覆盖主题标签（去重、去空、最多 6 个）。
    /// `themes` 以半角逗号分隔的 CSV 存一列，**tag 字符串里不能出现逗号**——
    /// 否则存为 "Tokyo, Japan"，读回来会被 themeArray split 成两个 tag，绕过 6 个上限、
    /// 污染聚合。写入前同时清掉半角/全角逗号。
    func setThemes(_ newThemes: [String]) {
        themes = DiaryEntry.sanitizeThemes(newThemes)
    }

    /// `setThemes` 的纯函数版（不访问 Core Data，便于单测）。
    /// 规则：
    ///   1. 每条 tag 里的 `,` / `，` 替换成空格（避免 CSV 分裂和 unicode 不一致）
    ///   2. 折叠内部连续空白为单空格（"Tokyo, Japan" → "Tokyo Japan" 而不是 "Tokyo  Japan"）
    ///   3. trim 首尾空白、丢空
    ///   4. **单 tag 最多 50 个字符**——防 AI 回一个超长字符串撑爆 themes 列、CloudKit 同步超限、
    ///      以及 `aggregateThemes` 里一个 bucket 吃掉所有条目
    ///   5. 按 lowercased key 去重，保留首次出现的原文大小写
    ///   6. 最多取前 6 条
    ///   7. 全空 → nil，其它 → `"t1,t2,..."` CSV
    static let maxThemeTagLength = 50
    static func sanitizeThemes(_ rawThemes: [String]) -> String? {
        let cleaned = rawThemes
            .map { raw -> String in
                raw
                    .replacingOccurrences(of: ",", with: " ")
                    .replacingOccurrences(of: "，", with: " ")
                    .split(whereSeparator: { $0.isWhitespace })  // 折叠所有空白（含替换出来的双空格）
                    .joined(separator: " ")
            }
            .map { String($0.prefix(maxThemeTagLength)) }  // per-tag 长度上限
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let uniq = cleaned.filter { seen.insert($0.lowercased()).inserted }
        let capped = Array(uniq.prefix(6))
        return capped.isEmpty ? nil : capped.joined(separator: ",")
    }
}

// MARK: - Embedding (Float32 semantic vector ↔ Data)
//
// **格式 V1**：`[4B magic "EMB1"][4B UInt32 LE dimension][N × Float32 LE]`
//
// 加头是为了让"换模型 / 换维度"时老数据**能被 runtime 识别**而不是按 raw bytes 当成别的维度解。
// 原实现是纯 raw Float32 dump，如果 OpenAI 升级 text-embedding-3-small 的维度（或我们切别的模型），
// 老数据会被反序列化成错误长度的向量，cosineSimilarity 恒 0 / 无法检测到需要重新 backfill。
//
// 向后兼容：V1 magic 存在 → 按 header 解；不存在 → 假设是 legacy raw Float32 dump，按原逻辑吃掉。
// 老条目会在下次编辑 / 一键重建 embedding 时升级到 V1 格式。
extension DiaryEntry {
    private static let embeddingMagicV1: [UInt8] = Array("EMB1".utf8)  // 4 bytes

    /// 读取 embedding 向量；nil 表示尚未生成 / 格式损坏
    ///
    /// **对齐说明（踩过的 crash）**：Core Data 的
    /// `allowsExternalBinaryDataStorage="YES"` blob 在 CloudKit 同步回来之后
    /// 物化出的 `Data` 的 backing buffer **不保证 4 字节对齐**。直接
    /// `buf.load(as: UInt32.self)` / `assumingMemoryBound(to: Float.self)` /
    /// `bindMemory(to: Float.self)` 会触发
    /// `Swift/UnsafeRawPointer.swift:449: Fatal error: load from misaligned raw pointer`
    /// （在发日记 → `NSPersistentStoreRemoteChange` → 读任意旧条目 embedding 的路径上观察到）。
    ///
    /// 解决：**不要**在 source buffer 上解释类型，用 `memcpy` 把字节拷进
    /// `[Float]` —— Array 的 backing 由分配器保证 `alignof(Float)` 对齐，
    /// 对源端的对齐就没有任何要求，memcpy 本身是逐字节的。
    var embeddingVector: [Float]? {
        guard let data = embedding, !data.isEmpty else { return nil }

        // V1 header 检测：前 4 字节等于 "EMB1"，后 4 字节是 LE UInt32 dimension
        let headerLen = 8
        if data.count >= headerLen {
            let magicMatch = data.prefix(4).elementsEqual(Self.embeddingMagicV1)
            if magicMatch {
                var dimLE: UInt32 = 0
                withUnsafeMutableBytes(of: &dimLE) { dst in
                    data.withUnsafeBytes { src in
                        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                        memcpy(dstBase, srcBase.advanced(by: 4), 4)
                    }
                }
                let dim = Int(UInt32(littleEndian: dimLE))
                let payloadBytes = data.count - headerLen
                let expected = dim * MemoryLayout<Float>.size
                guard dim > 0, payloadBytes == expected else {
                    Log.error("[DiaryEntry] embedding V1 dimension mismatch: header=\(dim), bytes=\(payloadBytes)", category: .persistence)
                    return nil
                }
                var floats = [Float](repeating: 0, count: dim)
                floats.withUnsafeMutableBytes { dst in
                    data.withUnsafeBytes { src in
                        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                        memcpy(dstBase, srcBase.advanced(by: headerLen), expected)
                    }
                }
                return floats
            }
        }

        // Legacy raw Float32 dump fallback
        let count = data.count / MemoryLayout<Float>.size
        // 字节数不是 4 的倍数 → 格式损坏，不悄悄截断，让 backfill 识别后重建
        guard count > 0, data.count == count * MemoryLayout<Float>.size else {
            if !data.isEmpty {
                Log.error("[DiaryEntry] embedding legacy blob size \(data.count) not aligned to Float", category: .persistence)
            }
            return nil
        }
        let byteCount = count * MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        floats.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                memcpy(dstBase, srcBase, byteCount)
            }
        }
        return floats
    }

    /// 写入 embedding 向量（永远写 V1 格式）
    func setEmbedding(_ vector: [Float]) {
        var payload = Data(Self.embeddingMagicV1)
        var dim = UInt32(vector.count).littleEndian
        payload.append(Data(bytes: &dim, count: MemoryLayout<UInt32>.size))
        vector.withUnsafeBufferPointer { buf in
            payload.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count).withMemoryRebound(to: UInt8.self) { raw in
                Data(bytes: raw.baseAddress!, count: raw.count)
            })
        }
        embedding = payload
    }
}

// MARK: - Word count helper
extension DiaryEntry {
    /// 基于当前 text 重算字数（中英文兼容：中文按字符、英文按空白分词）
    func recomputeWordCount() {
        wordCount = Int32(DiaryEntry.countWords(in: text ?? ""))
    }

    static func countWords(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // 中文按字符计数；英文 / 混合按空白分词计数；取两者和中的较大值作为合理估计
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
            || (0x3040...0x30FF).contains(scalar.value) // Hiragana + Katakana
            || (0xAC00...0xD7AF).contains(scalar.value) // Hangul
        }.count
        let latinWords = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.range(of: "[a-zA-Z0-9]", options: .regularExpression) != nil }
            .count
        return cjkCount + latinWords
    }
}

// MARK: - Image Management
extension DiaryEntry {
    /// Returns array of image file names
    var imageFileNameArray: [String] {
        guard let names = imageFileNames, !names.isEmpty else { return [] }
        return names.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    
    /// Saves images data for CloudKit sync (synchronous - deprecated, use saveImagesForSyncAsync instead)
    @available(*, deprecated, message: "Use saveImagesForSyncAsync to avoid blocking main thread")
    func saveImagesForSync(_ images: [Data]) {
        guard !images.isEmpty else {
            imagesData = nil
            return
        }

        // Use serial queue to avoid blocking main thread completely
        // But still complete before returning
        let compressedImages = images.map { DiaryEntry.compressImageData($0) }

        // Encode as array
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: compressedImages, requiringSecureCoding: false)
            imagesData = encoded
            Log.info("[DiaryEntry] Saved \(images.count) images for sync, total size: \(encoded.count) bytes", category: .persistence)
        } catch {
            Log.error("[DiaryEntry] Failed to encode images: \(error)", category: .persistence)
        }
    }
    
    /// 异步保存图片用于 CloudKit 同步（避免阻塞主线程）
    func saveImagesForSyncAsync(_ images: [Data]) async {
        guard !images.isEmpty else {
            // 空列表也要走 context 队列写，不能在任意线程直接改 managed object
            await writeImagesDataOnContext(nil)
            return
        }

        // 使用 TaskGroup 并发压缩图片
        let compressedImages = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for imageData in images {
                group.addTask {
                    DiaryEntry.compressImageData(imageData)
                }
            }

            var results: [Data] = []
            for await compressed in group {
                results.append(compressed)
            }
            return results
        }

        // Encode as array
        do {
            let encoded = try NSKeyedArchiver.archivedData(withRootObject: compressedImages, requiringSecureCoding: false)
            // **必须**在 context 队列里写 managed object。原实现在任意 async 线程上 `imagesData = encoded`，
            // 对 main-queue context 来说是线程违规；会随机静默损坏对象图。
            await writeImagesDataOnContext(encoded)
            Log.info("[DiaryEntry] Saved \(images.count) images for sync, total size: \(encoded.count) bytes", category: .persistence)
        } catch {
            Log.error("[DiaryEntry] Failed to encode images: \(error)", category: .persistence)
        }
    }

    /// 把 `imagesData` 的写入序列化到 managed object 所在的 context 队列。
    /// 没有 context（对象已被删除）则静默跳过。
    private func writeImagesDataOnContext(_ encoded: Data?) async {
        guard let context = self.managedObjectContext else { return }
        await context.perform {
            self.imagesData = encoded
        }
    }
    
    /// Loads images from synced data
    func loadImagesFromSync() -> [Data] {
        guard let data = imagesData else { return [] }
        
        do {
            if let images = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSData.self], from: data) as? [Data] {
                Log.info("[DiaryEntry] Loaded \(images.count) images from sync", category: .persistence)
                return images
            }
        } catch {
            Log.error("[DiaryEntry] Failed to decode images: \(error)", category: .persistence)
        }
        
        return []
    }
    
    /// Returns URLs for all images
    var imageURLs: [URL] {
        imageFileNameArray.compactMap { fileName in
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent(fileName)
        }
    }
    
    /// Adds an image file name to the entry
    func addImageFileName(_ fileName: String) {
        // **CSV 消毒**：`imageFileNames` 是 `","` 分隔的 CSV。虽然 app 自己生成的都是 UUID-based、
        // 不含逗号，但来自导入 / 恢复 / 以后的 CloudKit sync 的字段不能 100% 信任，fileName 里有
        // `","` 会把一条拆成两个鬼条目。把逗号替换掉再写入，保持 CSV 解析语义稳定。
        let sanitized = fileName
            .replacingOccurrences(of: ",", with: "_")
            .replacingOccurrences(of: "，", with: "_")
        guard !sanitized.isEmpty else { return }
        var fileNames = imageFileNameArray
        if !fileNames.contains(sanitized) {
            fileNames.append(sanitized)
            imageFileNames = fileNames.joined(separator: ",")
        }
    }
    
    /// Removes an image file name from the entry
    func removeImageFileName(_ fileName: String) {
        var fileNames = imageFileNameArray
        fileNames.removeAll { $0 == fileName }
        imageFileNames = fileNames.isEmpty ? nil : fileNames.joined(separator: ",")
    }
    
    /// Saves image data to iCloud-synced documents directory and returns the file name
    static func saveImageToDocuments(_ imageData: Data, fileName: String? = nil) throws -> String {
        let fileName = fileName ?? "\(UUID().uuidString).jpg"
        
        // Always save to local first
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localImagesDir = documentsPath.appendingPathComponent("LumoryImages")
        
        // Create directory if needed
        if !FileManager.default.fileExists(atPath: localImagesDir.path) {
            try FileManager.default.createDirectory(at: localImagesDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        let localFileURL = localImagesDir.appendingPathComponent(fileName)
        try imageData.write(to: localFileURL)
        Log.info("[DiaryEntry] Saved image locally to: \(localFileURL.path)", category: .persistence)
        
        // Also try to save to iCloud if available
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let iCloudImagesDir = iCloudURL.appendingPathComponent("Documents/LumoryImages")
            
            if !FileManager.default.fileExists(atPath: iCloudImagesDir.path) {
                try? FileManager.default.createDirectory(at: iCloudImagesDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            let iCloudFileURL = iCloudImagesDir.appendingPathComponent(fileName)
            try? imageData.write(to: iCloudFileURL)
            Log.info("[DiaryEntry] Also saved image to iCloud: \(iCloudFileURL.path)", category: .persistence)
        }
        
        return fileName
    }
    
    /// Deletes an image file from documents directory
    static func deleteImageFromDocuments(_ fileName: String) throws {
        let fileURL = getImageURL(for: fileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Gets the proper URL for image storage (iCloud or local)
    private static func getImageURL(for fileName: String) -> URL {
        // Try to use iCloud container
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            // Use a specific directory for images in iCloud
            let imagesURL = iCloudURL.appendingPathComponent("Documents/LumoryImages")
            Log.info("[DiaryEntry] Using iCloud URL for image: \(imagesURL.path)", category: .persistence)
            return imagesURL.appendingPathComponent(fileName)
        } else {
            // Fallback to local documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let imagesURL = documentsPath.appendingPathComponent("LumoryImages")
            Log.info("[DiaryEntry] iCloud not available, using local URL for image: \(imagesURL.path)", category: .persistence)
            return imagesURL.appendingPathComponent(fileName)
        }
    }
    
    /// Loads image data from file name with caching — **静态版本**，不需要 DiaryEntry 实例。
    /// 用在后台 Task 里做缩略图加载（列表 cell）——避免捕获 managed object 跨线程。
    /// 逻辑和实例方法一致：iCloud / LumoryImages / 老位置依次回退。
    static func loadImageData(fileName: String) -> Data? {
        let cacheKey = fileName as NSString
        var cachedData: Data?
        DiaryEntry.cacheQueue.sync {
            cachedData = DiaryEntry.imageCache.object(forKey: cacheKey) as Data?
        }
        if let data = cachedData { return data }

        // iCloud
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let iCloudFileURL = iCloudURL.appendingPathComponent("Documents/LumoryImages").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: iCloudFileURL.path),
               let data = try? Data(contentsOf: iCloudFileURL) {
                DiaryEntry.cacheQueue.async(flags: .barrier) {
                    DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                return data
            }
        }

        // Local LumoryImages
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFileURL = documentsPath.appendingPathComponent("LumoryImages").appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: localFileURL.path),
           let data = try? Data(contentsOf: localFileURL) {
            DiaryEntry.cacheQueue.async(flags: .barrier) {
                DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            }
            return data
        }

        // Legacy: bare Documents root
        let oldFileURL = documentsPath.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: oldFileURL.path),
           let data = try? Data(contentsOf: oldFileURL) {
            DiaryEntry.cacheQueue.async(flags: .barrier) {
                DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            }
            return data
        }

        return nil
    }

    /// Loads image data from file name with caching
    func loadImageData(fileName: String) -> Data? {
        // Check cache first
        let cacheKey = fileName as NSString
        
        // Thread-safe cache read
        var cachedData: Data?
        DiaryEntry.cacheQueue.sync {
            cachedData = DiaryEntry.imageCache.object(forKey: cacheKey) as Data?
        }
        
        if let data = cachedData {
            return data
        }
        
        // Try iCloud first
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let iCloudFileURL = iCloudURL.appendingPathComponent("Documents/LumoryImages").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: iCloudFileURL.path) {
                do {
                    let data = try Data(contentsOf: iCloudFileURL)
                    DiaryEntry.cacheQueue.async(flags: .barrier) {
                        DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                    }
                    return data
                } catch {
                    // 文件存在但读不出来——通常是 iCloud 延迟下载 / 权限 / 文件损坏。静默 try? 会让用户看到占位图没任何线索。
                    Log.error("[DiaryEntry] iCloud image read failed \(fileName): \(error)", category: .persistence)
                }
            }
        }

        // Try local
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFileURL = documentsPath.appendingPathComponent("LumoryImages").appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: localFileURL.path) {
            do {
                let data = try Data(contentsOf: localFileURL)
                DiaryEntry.cacheQueue.async(flags: .barrier) {
                    DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                return data
            } catch {
                Log.error("[DiaryEntry] Local image read failed \(fileName): \(error)", category: .persistence)
            }
        }

        // Try old location for backward compatibility
        let oldFileURL = documentsPath.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: oldFileURL.path) {
            do {
                let data = try Data(contentsOf: oldFileURL)
                DiaryEntry.cacheQueue.async(flags: .barrier) {
                    DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                return data
            } catch {
                Log.error("[DiaryEntry] Legacy image read failed \(fileName): \(error)", category: .persistence)
            }
        }

        Log.info("[DiaryEntry] Image not found: \(fileName)", category: .persistence)
        return nil
    }
    
    /// Loads all images as Data array (synchronous - deprecated, use loadAllImageDataAsync instead)
    @available(*, deprecated, message: "Use loadAllImageDataAsync to avoid blocking main thread")
    func loadAllImageData() -> [Data] {
        // First try to load from synced data
        let syncedImages = loadImagesFromSync()
        if !syncedImages.isEmpty {
            return syncedImages
        }

        // Fallback to loading from files sequentially to avoid blocking with group.wait()
        let fileNames = imageFileNameArray
        guard !fileNames.isEmpty else { return [] }

        // Load images sequentially (still on current thread, but no group.wait())
        return fileNames.compactMap { loadImageData(fileName: $0) }
    }
    
    /// 异步加载所有图片（避免阻塞主线程）
    func loadAllImageDataAsync() async -> [Data] {
        // First try to load from synced data
        let syncedImages = loadImagesFromSync()
        if !syncedImages.isEmpty {
            return syncedImages
        }
        
        // Fallback to loading from files with concurrent loading
        let fileNames = imageFileNameArray
        guard !fileNames.isEmpty else { return [] }
        
        return await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
            for fileName in fileNames {
                group.addTask { [weak self] in
                    self?.loadImageData(fileName: fileName)
                }
            }
            
            var results: [Data] = []
            for await data in group {
                if let data = data {
                    results.append(data)
                }
            }
            return results
        }
    }
    
    /// 删除此 entry 绑定的音频文件。覆盖 iCloud / LumoryAudio / 老扁平 Documents 三处——
    /// 同一个 fileName 可能在多处都有副本（iCloud 下载缓存 + 本地原始），漏删任意一处都会
    /// 留成孤儿 .m4a 文件在用户的磁盘/iCloud 上累积。
    ///
    /// **必须在 `viewContext.delete(entry)` 之前调用**——managed object 被 delete 之后
    /// `audioFileName` 的读取会 crash 或返回脏数据。三处删除点（HomeView.deleteEntry /
    /// DiaryDetailView delete button / SettingsView.deleteAllEntries）都调用本方法。
    func deleteAudioFile() {
        guard let fileName = audioFileName, !fileName.isEmpty else { return }
        let fm = FileManager.default

        // iCloud 位置
        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let iCloudFile = iCloudURL
                .appendingPathComponent("Documents/LumoryAudio")
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: iCloudFile.path) {
                try? fm.removeItem(at: iCloudFile)
            }
        }

        // 本地 LumoryAudio/
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFile = docs.appendingPathComponent("LumoryAudio").appendingPathComponent(fileName)
        if fm.fileExists(atPath: localFile.path) {
            try? fm.removeItem(at: localFile)
        }

        // 老的扁平 Documents/ 位置（向后兼容）
        let legacyFile = docs.appendingPathComponent(fileName)
        if fm.fileExists(atPath: legacyFile.path) {
            try? fm.removeItem(at: legacyFile)
        }
    }

    /// Deletes all images associated with this entry
    func deleteAllImages() {
        for fileName in imageFileNameArray {
            // Remove from cache
            DiaryEntry.cacheQueue.async(flags: .barrier) {
                DiaryEntry.imageCache.removeObject(forKey: fileName as NSString)
            }
            // Delete from disk
            try? DiaryEntry.deleteImageFromDocuments(fileName)
        }
        imageFileNames = nil
        imagesData = nil
    }
    
    /// Replaces all images with new ones
    func replaceImages(with newImageData: [Data]) throws {
        // Delete existing images
        deleteAllImages()
        
        // Save new images
        var newFileNames: [String] = []
        for imageData in newImageData {
            let fileName = try DiaryEntry.saveImageToDocuments(imageData)
            newFileNames.append(fileName)
        }
        
        // Update file names
        imageFileNames = newFileNames.isEmpty ? nil : newFileNames.joined(separator: ",")
    }
    
    /// Migrates images from local storage to iCloud if needed
    func migrateImagesToiCloud() {
        guard !imageFileNameArray.isEmpty else { return }
        
        for fileName in imageFileNameArray {
            // Check if image exists in iCloud location
            let iCloudURL = DiaryEntry.getImageURL(for: fileName)
            if !FileManager.default.fileExists(atPath: iCloudURL.path) {
                // Try to load from old location
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let oldURL = documentsPath.appendingPathComponent(fileName)
                
                if let imageData = try? Data(contentsOf: oldURL) {
                    // Save to new location
                    do {
                        _ = try DiaryEntry.saveImageToDocuments(imageData, fileName: fileName)
                        Log.info("[DiaryEntry] Migrated image \(fileName) to iCloud", category: .persistence)
                        
                        // Delete from old location
                        try? FileManager.default.removeItem(at: oldURL)
                    } catch {
                        Log.error("[DiaryEntry] Failed to migrate image \(fileName): \(error)", category: .persistence)
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    static func compressImageData(_ imageData: Data) -> Data {
        #if os(iOS)
        guard let uiImage = UIImage(data: imageData) else { return imageData }

        // Smart compression based on image size
        let pixelCount = Int(uiImage.size.width * uiImage.scale * uiImage.size.height * uiImage.scale)
        let compressionQuality: CGFloat

        switch pixelCount {
        case 0..<1_000_000: // < 1MP
            compressionQuality = 0.9
        case 1_000_000..<4_000_000: // 1-4MP
            compressionQuality = 0.7
        case 4_000_000..<8_000_000: // 4-8MP
            compressionQuality = 0.5
        default: // > 8MP
            compressionQuality = 0.3
        }

        // Also resize if too large
        //
        // 老实现用 `UIGraphicsBeginImageContextWithOptions` + `UIGraphicsGetImageFromCurrentImageContext`
        // 已于 iOS 17 deprecated；改走 `UIGraphicsImageRenderer`（modern API，自动处理 color space / Retina）。
        // `format` 显式保持默认（scale = 1.0, opaque = false）—— 不要手动把 `.opaque = true`，
        // 虽然 HEIC/JPEG 最终都丢 alpha，但渲染中间产物保持默认更稳。
        let renderedImage: UIImage
        let maxDimension: CGFloat = 2048
        if uiImage.size.width > maxDimension || uiImage.size.height > maxDimension {
            let scale = min(maxDimension / uiImage.size.width, maxDimension / uiImage.size.height)
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            renderedImage = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            renderedImage = uiImage
        }

        // HEIC 优先，失败回退 JPEG。
        //
        // 为什么需要回退：
        //   - 非 RGB 色彩空间（CMYK / CIImage-only UIImage）走 HEIC encoder 会 Finalize 失败
        //   - 老设备 / 历史上模拟器某些组合不支持 HEIC 编码
        //   - `cgImage` 为 nil 的 UIImage 在 heicData 里直接返回 nil
        // 如果 HEIC 和 JPEG 都失败（基本只发生在 UIImage 构造本身就损坏时），
        // 退回原始 imageData，保证不会把 0 字节写进 blob。
        if let heic = renderedImage.heicData(compressionQuality: compressionQuality) {
            return heic
        }
        return renderedImage.jpegData(compressionQuality: compressionQuality) ?? imageData

        #else
        guard let nsImage = NSImage(data: imageData) else { return imageData }
        
        // For macOS, similar logic
        let pixelCount = Int(nsImage.size.width * nsImage.size.height)
        let compressionQuality: Float
        
        switch pixelCount {
        case 0..<1_000_000:
            compressionQuality = 0.9
        case 1_000_000..<4_000_000:
            compressionQuality = 0.7
        case 4_000_000..<8_000_000:
            compressionQuality = 0.5
        default:
            compressionQuality = 0.3
        }
        
        if let tiffData = nsImage.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData) {
            return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) ?? imageData
        }
        
        return imageData
        #endif
    }
    
    /// Clear all cached images
    static func clearImageCache() {
        cacheQueue.async(flags: .barrier) {
            imageCache.removeAllObjects()
        }
    }
} 