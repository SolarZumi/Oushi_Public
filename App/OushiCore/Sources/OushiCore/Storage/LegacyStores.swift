// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import SwiftData

/// The files 1.0's development builds kept: a SwiftData ledger by local identifier and the batch as JSON (and
/// beside them a mirrored copy of the ledger, which is not read: the new store sends its own copy up). Read once
/// into the new store, then removed.
public enum LegacyStores {
    public struct Contents: Sendable {
        public var records: [PhotoRecord] = []
        public var batch: ReviewBatch?
    }

    /// The old ledger's row, under its old entity name so the old file opens.
    @Model
    final class PhotoRecordEntity {
        @Attribute(.unique) var id: String
        var cloudID: String?
        var seenAt: Date?
        var pendingSince: Date?

        init(id: String, cloudID: String?, seenAt: Date?, pendingSince: Date?) {
            self.id = id
            self.cloudID = cloudID
            self.seenAt = seenAt
            self.pendingSince = pendingSince
        }
    }

    static func ledgerURL(in directory: URL) -> URL { directory.appendingPathComponent("review-ledger.store") }
    static func batchURL(in directory: URL) -> URL { directory.appendingPathComponent("review-batch.json") }

    /// Every file an old build may have left, with SQLite's side files.
    static func files(in directory: URL) -> [URL] {
        var urls: [URL] = []
        for name in ["review-ledger.store", "review-cloud.store"] {
            for suffix in ["", "-shm", "-wal"] { urls.append(directory.appendingPathComponent(name + suffix)) }
        }
        urls.append(batchURL(in: directory))
        urls.append(directory.appendingPathComponent("review-session.json"))
        return urls
    }

    public static func exist(in directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: ledgerURL(in: directory).path) || manager.fileExists(atPath: batchURL(in: directory).path)
    }

    /// Reads the old files. Blocks on the database; call off the main thread.
    public static func read(in directory: URL) throws -> Contents {
        var contents = Contents()
        let ledgerURL = ledgerURL(in: directory)
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let schema = Schema([PhotoRecordEntity.self])
            let configuration = ModelConfiguration("legacy", schema: schema, url: ledgerURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            contents.records = try context.fetch(FetchDescriptor<PhotoRecordEntity>()).map {
                PhotoRecord(id: $0.id, cloudID: $0.cloudID, seenAt: $0.seenAt, pendingSince: $0.pendingSince)
            }.filter { !$0.isBlank }
        }
        if let data = try? Data(contentsOf: batchURL(in: directory)) {
            contents.batch = try? JSONDecoder().decode(ReviewBatch.self, from: data)
        }
        return contents
    }

    public static func remove(in directory: URL) {
        for url in files(in: directory) { try? FileManager.default.removeItem(at: url) }
    }

    /// Moves files that could not be read out of the way, under a name that says so, so the new store goes on
    /// without them and they are not tried again at every launch.
    public static func setAside(in directory: URL) {
        let manager = FileManager.default
        for url in files(in: directory) where manager.fileExists(atPath: url.path) {
            let aside = url.appendingPathExtension("unreadable")
            try? manager.removeItem(at: aside)
            try? manager.moveItem(at: url, to: aside)
        }
    }
}
