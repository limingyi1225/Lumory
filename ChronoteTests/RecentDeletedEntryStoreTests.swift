import CoreData
import Foundation
import Testing
@testable import Lumory

@Suite(.serialized)
@MainActor
struct RecentDeletedEntryStoreTests {
    @Test func archiveAndRestore_roundTripsEntryFields() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RecentDeletedEntryStore.setRootDirectoryForTesting(tempRoot)
        defer {
            RecentDeletedEntryStore.setRootDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entryID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 123_456)

        let entry = DiaryEntry(context: context)
        entry.id = entryID
        entry.date = date
        entry.text = "Recover me"
        entry.summary = "Recover summary"
        entry.moodValue = 0.8
        entry.setThemes(["Travel"])
        entry.recomputeWordCount()
        try context.save()

        let snapshot = EntryDeletionSnapshot(entry: entry)
        context.delete(entry)
        try context.save()

        await RecentDeletedEntryStore.archive(snapshot: snapshot)
        let previews = await RecentDeletedEntryStore.previews()
        #expect(previews.count == 1)
        #expect(previews.first?.entryID == entryID)

        let restored = await RecentDeletedEntryStore.restore(archiveID: try #require(previews.first?.id), into: context)
        #expect(restored)

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let restoredEntry = try #require(try context.fetch(request).first)
        #expect(restoredEntry.wrappedText == "Recover me")
        #expect(restoredEntry.summary == "Recover summary")
        #expect(restoredEntry.date == date)
        #expect(restoredEntry.moodValue == 0.8)
        #expect(restoredEntry.themeArray == ["Travel"])
        #expect(await RecentDeletedEntryStore.previews().isEmpty)
    }

    @Test func archive_marksRootDirectoryExcludedFromBackup() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RecentDeletedEntryStore.setRootDirectoryForTesting(tempRoot)
        defer {
            RecentDeletedEntryStore.setRootDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = Date(timeIntervalSinceReferenceDate: 123)
        entry.text = "Local archive"
        entry.moodValue = 0.5
        entry.recomputeWordCount()
        try context.save()

        let snapshot = EntryDeletionSnapshot(entry: entry)

        await RecentDeletedEntryStore.archive(snapshot: snapshot)

        let values = try tempRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func archive_preservesEntryWhenAudioFileIsMissing() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RecentDeletedEntryStore.setRootDirectoryForTesting(tempRoot)
        defer {
            RecentDeletedEntryStore.setRootDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entryID = UUID()
        let entry = DiaryEntry(context: context)
        entry.id = entryID
        entry.date = Date()
        entry.text = "Missing audio"
        entry.moodValue = 0.5
        entry.audioFileName = "missing-\(UUID().uuidString).m4a"
        try context.save()

        let snapshot = EntryDeletionSnapshot(entry: entry)
        let archived = await RecentDeletedEntryStore.archive(snapshot: snapshot)

        #expect(archived)
        let preview = try #require((await RecentDeletedEntryStore.previews()).first)
        #expect(preview.hasAudio == false)

        context.delete(entry)
        try context.save()
        #expect(await RecentDeletedEntryStore.restore(archiveID: preview.id, into: context))

        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        let restored = try #require(try context.fetch(request).first)
        #expect(restored.wrappedText == "Missing audio")
        #expect(restored.audioFileName == nil)
    }

    @Test func restoreFailureKeepsArchiveForRetry() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RecentDeletedEntryStore.setRootDirectoryForTesting(tempRoot)
        let audioFileName = "recent-restore-\(UUID().uuidString).m4a"
        defer {
            RecentDeletedEntryStore.setRootDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
            DiaryEntry.deleteAudioFromDocuments(audioFileName)
        }

        let audioDirectory = try LumoryAttachmentPaths.ensureLocalDirectory(for: .audio)
        try Data("audio".utf8).write(to: audioDirectory.appendingPathComponent(audioFileName))

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entryID = UUID()
        let entry = DiaryEntry(context: context)
        entry.id = entryID
        entry.date = Date()
        entry.text = "Audio restore"
        entry.moodValue = 0.5
        entry.audioFileName = audioFileName
        try context.save()

        let snapshot = EntryDeletionSnapshot(entry: entry)
        context.delete(entry)
        try context.save()
        #expect(await RecentDeletedEntryStore.archive(snapshot: snapshot))
        let archiveID = try #require((await RecentDeletedEntryStore.previews()).first?.id)
        let archivedAudioURL = tempRoot
            .appendingPathComponent(archiveID.uuidString, isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(audioFileName)
        try FileManager.default.removeItem(at: archivedAudioURL)

        let restored = await RecentDeletedEntryStore.restore(archiveID: archiveID, into: context)

        #expect(restored == false)
        #expect((await RecentDeletedEntryStore.previews()).map(\.id).contains(archiveID))
        let request: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", entryID as NSUUID)
        #expect(try context.fetch(request).isEmpty)
    }

    @Test func purgeAll_removesExistingArchives() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RecentDeletedEntryStore.setRootDirectoryForTesting(tempRoot)
        defer {
            RecentDeletedEntryStore.setRootDirectoryForTesting(nil)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = Date()
        entry.text = "Purge me"
        entry.moodValue = 0.5
        try context.save()

        #expect(await RecentDeletedEntryStore.archive(snapshot: EntryDeletionSnapshot(entry: entry)))
        #expect(await RecentDeletedEntryStore.count() == 1)

        await RecentDeletedEntryStore.purgeAll()

        #expect(await RecentDeletedEntryStore.count() == 0)
    }
}
