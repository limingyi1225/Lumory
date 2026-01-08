import SwiftUI
import CoreData

// MARK: - Core Data DiaryEntry 扩展
extension DiaryEntry {
    // Image cache - thread-safe
    private static let imageCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 50 // Max 50 images in cache
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB limit
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
    
    /// Photos data array
    var photos: [Data]? {
        let imageData = loadAllImageData()
        return imageData.isEmpty ? nil : imageData
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
            print("[DiaryEntry] Saved \(images.count) images for sync, total size: \(encoded.count) bytes")
        } catch {
            print("[DiaryEntry] Failed to encode images: \(error)")
        }
    }
    
    /// 异步保存图片用于 CloudKit 同步（避免阻塞主线程）
    func saveImagesForSyncAsync(_ images: [Data]) async {
        guard !images.isEmpty else {
            imagesData = nil
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
            imagesData = encoded
            print("[DiaryEntry] Saved \(images.count) images for sync, total size: \(encoded.count) bytes")
        } catch {
            print("[DiaryEntry] Failed to encode images: \(error)")
        }
    }
    
    /// Loads images from synced data
    func loadImagesFromSync() -> [Data] {
        guard let data = imagesData else { return [] }
        
        do {
            if let images = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSData.self], from: data) as? [Data] {
                print("[DiaryEntry] Loaded \(images.count) images from sync")
                return images
            }
        } catch {
            print("[DiaryEntry] Failed to decode images: \(error)")
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
        var fileNames = imageFileNameArray
        if !fileNames.contains(fileName) {
            fileNames.append(fileName)
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
        print("[DiaryEntry] Saved image locally to: \(localFileURL.path)")
        
        // Also try to save to iCloud if available
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.Mingyi.Lumory") {
            let iCloudImagesDir = iCloudURL.appendingPathComponent("Documents/LumoryImages")
            
            if !FileManager.default.fileExists(atPath: iCloudImagesDir.path) {
                try? FileManager.default.createDirectory(at: iCloudImagesDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            let iCloudFileURL = iCloudImagesDir.appendingPathComponent(fileName)
            try? imageData.write(to: iCloudFileURL)
            print("[DiaryEntry] Also saved image to iCloud: \(iCloudFileURL.path)")
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
            print("[DiaryEntry] Using iCloud URL for image: \(imagesURL.path)")
            return imagesURL.appendingPathComponent(fileName)
        } else {
            // Fallback to local documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let imagesURL = documentsPath.appendingPathComponent("LumoryImages")
            print("[DiaryEntry] iCloud not available, using local URL for image: \(imagesURL.path)")
            return imagesURL.appendingPathComponent(fileName)
        }
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
                if let data = try? Data(contentsOf: iCloudFileURL) {
                    // Cache the loaded data
                    DiaryEntry.cacheQueue.async(flags: .barrier) {
                        DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                    }
                    return data
                }
            }
        }
        
        // Try local
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFileURL = documentsPath.appendingPathComponent("LumoryImages").appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: localFileURL.path) {
            if let data = try? Data(contentsOf: localFileURL) {
                // Cache the loaded data
                DiaryEntry.cacheQueue.async(flags: .barrier) {
                    DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                return data
            }
        }
        
        // Try old location for backward compatibility
        let oldFileURL = documentsPath.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: oldFileURL.path) {
            if let data = try? Data(contentsOf: oldFileURL) {
                // Cache the loaded data
                DiaryEntry.cacheQueue.async(flags: .barrier) {
                    DiaryEntry.imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                return data
            }
        }
        
        print("[DiaryEntry] Image not found: \(fileName)")
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
                        print("[DiaryEntry] Migrated image \(fileName) to iCloud")
                        
                        // Delete from old location
                        try? FileManager.default.removeItem(at: oldURL)
                    } catch {
                        print("[DiaryEntry] Failed to migrate image \(fileName): \(error)")
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private static func compressImageData(_ imageData: Data) -> Data {
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
        let maxDimension: CGFloat = 2048
        if uiImage.size.width > maxDimension || uiImage.size.height > maxDimension {
            let scale = min(maxDimension / uiImage.size.width, maxDimension / uiImage.size.height)
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
            
            if let resizedImage = UIGraphicsGetImageFromCurrentImageContext() {
                return resizedImage.jpegData(compressionQuality: compressionQuality) ?? imageData
            }
        }
        
        return uiImage.jpegData(compressionQuality: compressionQuality) ?? imageData
        
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