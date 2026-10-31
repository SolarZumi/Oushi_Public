// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import SwiftData

/// The ledger's first on-disk schema. New versions are added beside it and reached through `LedgerMigrationPlan`.
///
/// Two stores share one container: the synced one holds every photo's state under its iCloud Photos identifier
/// and is mirrored to CloudKit while the user wants it; the local one holds what is this device's own business
/// (which local identifier is which photo, states of photos iCloud does not know, the batch on screen).
public enum LedgerSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [SyncedPhotoState.self, LocalPhotoState.self, PhotoAlias.self, BatchRecord.self, LocalMetadata.self]
    }

    /// One photo's state as it travels through iCloud. CloudKit wants every attribute optional or defaulted and no
    /// unique constraint, so two devices writing the same photo before they sync leave two rows; readers fold them
    /// and writers write them all, so they converge. The identifier is kept in the history on deletion, so another
    /// device learns which photo was forgotten.
    @Model
    public final class SyncedPhotoState {
        #Index<SyncedPhotoState>([\.cloudID])
        @Attribute(.preserveValueOnDeletion) public var cloudID: String = ""
        public var seenAt: Date?
        public var pendingSince: Date?

        public init(cloudID: String, seenAt: Date?, pendingSince: Date?) {
            self.cloudID = cloudID
            self.seenAt = seenAt
            self.pendingSince = pendingSince
        }
    }

    /// A photo iCloud Photos has no identifier for (yet): its state lives on this device only, under the local
    /// identifier, and moves to the synced store once an identifier turns up.
    @Model
    public final class LocalPhotoState {
        @Attribute(.unique) public var localID: String
        public var seenAt: Date?
        public var pendingSince: Date?

        public init(localID: String, seenAt: Date?, pendingSince: Date?) {
            self.localID = localID
            self.seenAt = seenAt
            self.pendingSince = pendingSince
        }
    }

    /// PhotoKit's answer to "which photo is this": a local identifier and the iCloud identifier it stood for when
    /// asked. A cache; wrong after a restore, and then replaced.
    @Model
    public final class PhotoAlias {
        @Attribute(.unique) public var localID: String
        public var cloudID: String

        public init(localID: String, cloudID: String) {
            self.localID = localID
            self.cloudID = cloudID
        }
    }

    /// The batch on screen, saved whole. One row.
    @Model
    public final class BatchRecord {
        @Attribute(.unique) public var key: String
        public var payload: Data
        public var savedAt: Date

        public init(key: String, payload: Data, savedAt: Date) {
            self.key = key
            self.payload = payload
            self.savedAt = savedAt
        }
    }

    /// Small device-local values: the history token that marks how far remote changes have been read.
    @Model
    public final class LocalMetadata {
        @Attribute(.unique) public var key: String
        public var value: Data

        public init(key: String, value: Data) {
            self.key = key
            self.value = value
        }
    }
}

public typealias SyncedPhotoState = LedgerSchemaV1.SyncedPhotoState
public typealias LocalPhotoState = LedgerSchemaV1.LocalPhotoState
public typealias PhotoAlias = LedgerSchemaV1.PhotoAlias
public typealias BatchRecord = LedgerSchemaV1.BatchRecord
public typealias LocalMetadata = LedgerSchemaV1.LocalMetadata

enum LedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LedgerSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
