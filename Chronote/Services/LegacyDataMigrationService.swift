import Foundation
import CoreData

/// Service to migrate legacy DiaryStore data to Core Data if needed
struct LegacyDataMigrationService {
    static let migrationKey = "hasPerformedLegacyMigration"
    
    /// Check and migrate legacy diary.json file if exists
    @MainActor
    static func migrateIfNeeded(context: NSManagedObjectContext) async {
        // Check if migration already done
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            print("[LegacyMigration] Already migrated, skipping")
            return
        }
        
        // Check if legacy file exists
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacyURL = documentsURL.appendingPathComponent("diary.json")
        
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            print("[LegacyMigration] No legacy file found, marking as complete")
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        print("[LegacyMigration] Found legacy diary.json, starting migration...")
        
        do {
            // Load legacy data
            let data = try Data(contentsOf: legacyURL)
            let decoder = JSONDecoder()
            let legacyEntries = try decoder.decode([LegacyDiaryEntry].self, from: data)
            
            print("[LegacyMigration] Found \(legacyEntries.count) legacy entries")
            
            // Migrate each entry
            for legacyEntry in legacyEntries {
                // Check if entry already exists (by date and text)
                let fetchRequest: NSFetchRequest<DiaryEntry> = DiaryEntry.fetchRequest()
                fetchRequest.predicate = NSPredicate(
                    format: "date == %@ AND text == %@",
                    legacyEntry.date as NSDate,
                    legacyEntry.text
                )
                
                let existingCount = try context.count(for: fetchRequest)
                if existingCount > 0 {
                    print("[LegacyMigration] Entry already exists, skipping: \(legacyEntry.date)")
                    continue
                }
                
                // Create new Core Data entry
                let newEntry = DiaryEntry(context: context)
                newEntry.id = legacyEntry.id
                newEntry.date = legacyEntry.date
                newEntry.text = legacyEntry.text
                newEntry.summary = legacyEntry.summary
                newEntry.moodValue = legacyEntry.moodValue
                // hasMoodAnalysis property has been removed
                newEntry.audioFileName = legacyEntry.audioFileName
                
                // Note: LegacyDiaryEntry doesn't have photos property
                // If photos were stored separately, they would need to be migrated here
                
                print("[LegacyMigration] Migrated entry: \(legacyEntry.date)")
            }
            
            // Save context
            try context.save()
            print("[LegacyMigration] Successfully migrated \(legacyEntries.count) entries")
            
            // Mark migration as complete
            UserDefaults.standard.set(true, forKey: migrationKey)
            
            // Rename legacy file (don't delete in case user wants backup)
            let backupURL = documentsURL.appendingPathComponent("diary.json.backup")
            try FileManager.default.moveItem(at: legacyURL, to: backupURL)
            print("[LegacyMigration] Renamed legacy file to diary.json.backup")
            
        } catch {
            print("[LegacyMigration] Migration failed: \(error)")
        }
    }
    
    /// Clean up legacy files after successful migration
    static func cleanupLegacyFiles() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupURL = documentsURL.appendingPathComponent("diary.json.backup")
        
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.removeItem(at: backupURL)
                print("[LegacyMigration] Removed backup file")
            } catch {
                print("[LegacyMigration] Failed to remove backup: \(error)")
            }
        }
    }
}