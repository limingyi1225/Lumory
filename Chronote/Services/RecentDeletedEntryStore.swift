import CoreData
import Foundation

// MARK: - RecentDeletedEntryStore

/// Local-only 30-day archive for single-entry deletes.
///
/// This intentionally does not change the Core Data schema. A deleted entry is
/// archived only when the 4-second undo window commits; tapping undo before that
/// keeps the existing fast in-memory restore path.
enum RecentDeletedEntryStore {
    struct RecordPreview: Identifiable, Equatable, Sendable {
        let id: UUID
        let entryID: UUID
        let deletedAt: Date
        let expiresAt: Date
        let entryDate: Date?
        let text: String
        let summary: String?
        let moodValue: Double
        let imageCount: Int
        let hasAudio: Bool

        var displayText: String {
            let raw = summary?.isEmpty == false ? summary! : text
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? NSLocalizedString("无正文", comment: "Recently deleted empty entry fallback")
                : String(trimmed.prefix(90))
        }
    }

    private struct Metadata: Codable, Sendable {
        let archiveID: UUID
        let entryID: UUID
        let deletedAt: Date
        let expiresAt: Date
        let entryDate: Date?
        let text: String?
        let moodValue: Double
        let summary: String?
        let audioFileName: String?
        let imageFileNames: [String]
        let themes: String?
        let embedding: Data?
        let wordCount: Int32

        var preview: RecordPreview {
            RecordPreview(
                id: archiveID,
                entryID: entryID,
                deletedAt: deletedAt,
                expiresAt: expiresAt,
                entryDate: entryDate,
                text: text ?? "",
                summary: summary,
                moodValue: moodValue,
                imageCount: imageFileNames.count,
                hasAudio: audioFileName?.isEmpty == false
            )
        }
    }

    private static let folderName = "LumoryRecentlyDeleted"
    private static let metadataFileName = "metadata.json"
    private static let imageFolderName = "Images"
    private static let audioFolderName = "Audio"
    private static let imagesDataFileName = "imagesData.bin"
    private static let fileLock = NSLock()
    static let retentionDays = 30

    #if DEBUG
    private static var rootDirectoryOverride: URL?

    static func setRootDirectoryForTesting(_ url: URL?) {
        rootDirectoryOverride = url
    }
    #endif

    static func previews() async -> [RecordPreview] {
        await Task.detached(priority: .utility) {
            withFileLock {
                pruneExpiredSync()
                return allMetadataSync()
                    .map(\.preview)
                    .sorted { $0.deletedAt > $1.deletedAt }
            }
        }.value
    }

    static func count() async -> Int {
        let records = await previews()
        return records.count
    }

    @discardableResult
    static func archive(snapshot: EntryDeletionSnapshot) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                try withFileLock {
                    try archiveSync(snapshot: snapshot)
                    pruneExpiredSync()
                }
                return true
            } catch {
                Log.error("[RecentDeleted] archive failed: \(error.localizedDescription)", category: .persistence)
                return false
            }
        }.value
    }

    @MainActor
    static func restore(archiveID: UUID, into viewContext: NSManagedObjectContext) async -> Bool {
        let loaded = await Task.detached(priority: .utility) {
            withFileLock {
                loadArchiveSync(archiveID: archiveID)
            }
        }.value
        guard let loaded else { return false }

        let metadata = loaded.metadata
        let restoredID = existingEntryCount(id: metadata.entryID, in: viewContext) == 0
            ? metadata.entryID
            : UUID()
        let attachmentPlan = restoreAttachmentPlan(metadata: metadata, restoredID: restoredID)

        let attachmentsRestored = await Task.detached(priority: .utility) {
            withFileLock {
                do {
                    try restoreAttachmentFilesSync(loaded: loaded, plan: attachmentPlan)
                    return true
                } catch {
                    Log.error("[RecentDeleted] restore attachments failed: \(error.localizedDescription)", category: .persistence)
                    return false
                }
            }
        }.value
        guard attachmentsRestored else { return false }

        guard let entity = NSEntityDescription.entity(forEntityName: "DiaryEntry", in: viewContext) else {
            Log.error("[RecentDeleted] DiaryEntry entity not found", category: .persistence)
            return false
        }

        let entry = DiaryEntry(entity: entity, insertInto: viewContext)
        entry.id = restoredID
        entry.date = metadata.entryDate
        entry.text = metadata.text
        entry.moodValue = metadata.moodValue
        entry.summary = metadata.summary
        entry.audioFileName = attachmentPlan.audioFileName
        entry.imageFileNames = attachmentPlan.imageFileNames.isEmpty ? nil : attachmentPlan.imageFileNames.joined(separator: ",")
        entry.imagesData = loaded.imagesData
        entry.themes = metadata.themes
        entry.embedding = metadata.embedding
        entry.wordCount = metadata.wordCount

        do {
            try viewContext.save()
        } catch {
            Log.error("[RecentDeleted] restore save failed: \(error.localizedDescription)", category: .persistence)
            viewContext.rollback()
            await Task.detached(priority: .utility) {
                withFileLock {
                    removeRestoredAttachmentFilesSync(
                        imageFileNames: attachmentPlan.imageFileNames,
                        audioFileName: attachmentPlan.audioFileName
                    )
                }
            }.value
            return false
        }

        await delete(archiveID: archiveID)

        EntryWipeOrchestrator.performSingleDeleteCleanup()
        Log.info("[RecentDeleted] restored archive \(archiveID) as entry \(restoredID)", category: .persistence)
        return true
    }

    static func delete(archiveID: UUID) async {
        await Task.detached(priority: .utility) {
            withFileLock {
                deleteArchiveSync(archiveID: archiveID)
            }
        }.value
    }

    static func pruneExpired() async {
        await Task.detached(priority: .utility) {
            withFileLock {
                pruneExpiredSync()
            }
        }.value
    }

    static func purgeAll() async {
        await Task.detached(priority: .utility) {
            withFileLock {
                let root = rootDirectory()
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                excludeFromBackupIfNeeded(root)
            }
        }.value
    }

    // MARK: - Sync file helpers

    private struct LoadedArchive: Sendable {
        let metadata: Metadata
        let folder: URL
        let imagesData: Data?
    }

    private struct RestoreAttachmentPlan: Sendable {
        let imageFileNames: [String]
        let audioFileName: String?
    }

    private static func archiveSync(snapshot: EntryDeletionSnapshot) throws {
        let archiveID = UUID()
        let deletedAt = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: retentionDays, to: deletedAt)
            ?? deletedAt.addingTimeInterval(TimeInterval(retentionDays * 24 * 60 * 60))
        let root = try ensureRootDirectory()
        let folder = root.appendingPathComponent(archiveID.uuidString, isDirectory: true)
        do {
            let imageFolder = folder.appendingPathComponent(imageFolderName, isDirectory: true)
            let audioFolder = folder.appendingPathComponent(audioFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)

            let imageFileNames = snapshot.attachmentImageFileNames.compactMap {
                LumoryAttachmentPaths.normalizedFileName($0)
            }
            let hasImageBlobFallback = snapshot.imagesData != nil
            for fileName in imageFileNames {
                do {
                    try copyAttachment(fileName: fileName, kind: .image, to: imageFolder)
                } catch {
                    guard hasImageBlobFallback else { throw error }
                    Log.warning("[RecentDeleted] image file missing but imagesData fallback exists: \(fileName)", category: .persistence)
                }
            }
            let archivedAudioFileName: String?
            if let audioFileName = LumoryAttachmentPaths.normalizedFileName(snapshot.audioFileName) {
                do {
                    try copyAttachment(fileName: audioFileName, kind: .audio, to: audioFolder)
                    archivedAudioFileName = audioFileName
                } catch {
                    Log.warning("[RecentDeleted] audio file missing while archiving: \(audioFileName)", category: .persistence)
                    archivedAudioFileName = nil
                }
            } else {
                archivedAudioFileName = nil
            }
            if let imagesData = snapshot.imagesData {
                try imagesData.write(to: folder.appendingPathComponent(imagesDataFileName), options: .atomic)
            }

            let metadata = Metadata(
                archiveID: archiveID,
                entryID: snapshot.id,
                deletedAt: deletedAt,
                expiresAt: expiresAt,
                entryDate: snapshot.date,
                text: snapshot.text,
                moodValue: snapshot.moodValue,
                summary: snapshot.summary,
                audioFileName: archivedAudioFileName,
                imageFileNames: imageFileNames,
                themes: snapshot.themes,
                embedding: snapshot.embedding,
                wordCount: snapshot.wordCount
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL(in: folder), options: .atomic)
            Log.info("[RecentDeleted] archived entry \(snapshot.id) as \(archiveID)", category: .persistence)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func loadArchiveSync(archiveID: UUID) -> LoadedArchive? {
        let folder = rootDirectory().appendingPathComponent(archiveID.uuidString, isDirectory: true)
        guard let data = try? Data(contentsOf: metadataURL(in: folder)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        let imagesData = try? Data(contentsOf: folder.appendingPathComponent(imagesDataFileName))
        return LoadedArchive(metadata: metadata, folder: folder, imagesData: imagesData)
    }

    private static func restoreAttachmentPlan(metadata: Metadata, restoredID: UUID) -> RestoreAttachmentPlan {
        guard restoredID != metadata.entryID else {
            return RestoreAttachmentPlan(
                imageFileNames: metadata.imageFileNames,
                audioFileName: metadata.audioFileName
            )
        }

        return RestoreAttachmentPlan(
            imageFileNames: metadata.imageFileNames.map {
                regeneratedAttachmentFileName(original: $0, restoredID: restoredID)
            },
            audioFileName: metadata.audioFileName.map {
                regeneratedAttachmentFileName(original: $0, restoredID: restoredID)
            }
        )
    }

    private static func regeneratedAttachmentFileName(original: String, restoredID: UUID) -> String {
        let extensionPart = URL(fileURLWithPath: original).pathExtension
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        return "\(restoredID.uuidString)-\(UUID().uuidString)\(suffix)"
    }

    private static func restoreAttachmentFilesSync(loaded: LoadedArchive, plan: RestoreAttachmentPlan) throws {
        let imageFolder = loaded.folder.appendingPathComponent(imageFolderName, isDirectory: true)
        var missingImageFile = false
        for (sourceFileName, targetFileName) in zip(loaded.metadata.imageFileNames, plan.imageFileNames) {
            let fileName = sourceFileName
            let sourceURL = imageFolder.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: sourceURL) else {
                missingImageFile = true
                continue
            }
            do {
                _ = try DiaryEntry.saveImageToDocuments(data, fileName: targetFileName)
            } catch {
                Log.error("[RecentDeleted] restore image failed \(sourceFileName): \(error)", category: .persistence)
                throw error
            }
        }
        if missingImageFile, loaded.imagesData == nil {
            throw CocoaError(.fileReadNoSuchFile)
        }

        guard let sourceAudioFileName = loaded.metadata.audioFileName,
              let targetAudioFileName = plan.audioFileName else { return }
        let audioURL = loaded.folder
            .appendingPathComponent(audioFolderName, isDirectory: true)
            .appendingPathComponent(sourceAudioFileName)
        guard let safeName = LumoryAttachmentPaths.normalizedFileName(targetAudioFileName) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let audioData = try Data(contentsOf: audioURL)
        do {
            let localDir = try LumoryAttachmentPaths.ensureLocalDirectory(for: .audio)
            try audioData.write(to: localDir.appendingPathComponent(safeName), options: .atomic)
            if let iCloudDir = try? LumoryAttachmentPaths.ensureICloudDirectory(for: .audio) {
                try? audioData.write(to: iCloudDir.appendingPathComponent(safeName), options: .atomic)
            }
        } catch {
            Log.error("[RecentDeleted] restore audio failed \(sourceAudioFileName): \(error)", category: .persistence)
            throw error
        }
    }

    private static func removeRestoredAttachmentFilesSync(imageFileNames: [String], audioFileName: String?) {
        for fileName in imageFileNames {
            try? DiaryEntry.deleteImageFromDocuments(fileName)
        }
        if let audioFileName {
            DiaryEntry.deleteAudioFromDocuments(audioFileName)
        }
    }

    private static func allMetadataSync() -> [Metadata] {
        let root = rootDirectory()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { loadMetadataSync(in: $0) }
    }

    private static func pruneExpiredSync() {
        let now = Date()
        let root = rootDirectory()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for folder in children {
            guard let metadata = loadMetadataSync(in: folder) else {
                deleteArchiveFolderSync(folder)
                continue
            }
            if metadata.expiresAt <= now {
                deleteArchiveFolderSync(folder)
            }
        }
    }

    private static func deleteArchiveSync(archiveID: UUID) {
        let folder = rootDirectory().appendingPathComponent(archiveID.uuidString, isDirectory: true)
        deleteArchiveFolderSync(folder)
    }

    private static func deleteArchiveFolderSync(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func copyAttachment(fileName: String, kind: LumoryAttachmentPaths.Kind, to folder: URL) throws {
        guard let sourceURL = LumoryAttachmentPaths.existingURL(fileName: fileName, kind: kind) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let destination = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
    }

    private static func loadMetadataSync(in folder: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(in: folder)) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func existingEntryCount(id: UUID, in context: NSManagedObjectContext) -> Int {
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0
    }

    private static func metadataURL(in folder: URL) -> URL {
        folder.appendingPathComponent(metadataFileName)
    }

    private static func ensureRootDirectory() throws -> URL {
        let root = rootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackupIfNeeded(root)
        return root
    }

    private static func excludeFromBackupIfNeeded(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            Log.error("[RecentDeleted] failed to exclude archive folder from backup: \(error)", category: .persistence)
        }
    }

    private static func rootDirectory() -> URL {
        #if DEBUG
        if let rootDirectoryOverride {
            return rootDirectoryOverride
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func withFileLock<T>(_ work: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try work()
    }
}
