import Foundation

enum LumoryAttachmentPaths {
    enum Kind {
        case audio
        case image

        var directoryName: String {
            switch self {
            case .audio: return "LumoryAudio"
            case .image: return "LumoryImages"
            }
        }
    }

    private static let iCloudContainerIdentifier = "iCloud.com.Mingyi.Lumory"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func localDirectory(for kind: Kind) -> URL {
        documentsDirectory.appendingPathComponent(kind.directoryName)
    }

    static func iCloudDirectory(for kind: Kind) -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)?
            .appendingPathComponent("Documents")
            .appendingPathComponent(kind.directoryName)
    }

    static func legacyURL(fileName: String) -> URL {
        documentsDirectory.appendingPathComponent(fileName)
    }

    static func url(fileName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func candidateURLs(fileName: String, kind: Kind, iCloudDirectoryOverride: URL? = nil) -> [URL] {
        var urls: [URL] = []
        if let iCloudDirectory = iCloudDirectoryOverride ?? iCloudDirectory(for: kind) {
            urls.append(url(fileName: fileName, in: iCloudDirectory))
        }
        urls.append(localDirectory(for: kind).appendingPathComponent(fileName))
        urls.append(legacyURL(fileName: fileName))
        return urls
    }

    static func existingURL(fileName: String, kind: Kind, iCloudDirectoryOverride: URL? = nil) -> URL? {
        candidateURLs(fileName: fileName, kind: kind, iCloudDirectoryOverride: iCloudDirectoryOverride)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func existingAudioURL(fileName: String) -> URL? {
        existingURL(fileName: fileName, kind: .audio)
    }

    @discardableResult
    static func ensureLocalDirectory(for kind: Kind) throws -> URL {
        let directory = localDirectory(for: kind)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func ensureICloudDirectory(for kind: Kind) throws -> URL? {
        guard let directory = iCloudDirectory(for: kind) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func deleteAllCopies(fileName: String, kind: Kind) throws -> Int {
        let fm = FileManager.default
        var firstError: Error?
        var removedCount = 0

        for fileURL in candidateURLs(fileName: fileName, kind: kind) {
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fm.removeItem(at: fileURL)
                removedCount += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError {
            throw firstError
        }
        return removedCount
    }
}
