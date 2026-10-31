// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// What the app remembers about one photo.
///
/// `id` is PhotoKit's local identifier, which only means something in the library it came from. `cloudID` is the
/// iCloud Photos identifier, which survives restoring a backup or moving to a new phone; when a record's local
/// identifier no longer matches anything, the cloud identifier is how it finds its photo again.
public struct PhotoRecord: Codable, Equatable, Sendable {
    public var id: String
    public var cloudID: String?
    /// When the photo was last swiped past.
    public var seenAt: Date?
    /// When the photo was queued for deletion; nil while it is not in the pool.
    public var pendingSince: Date?

    public init(id: String, cloudID: String? = nil, seenAt: Date? = nil, pendingSince: Date? = nil) {
        self.id = id
        self.cloudID = cloudID
        self.seenAt = seenAt
        self.pendingSince = pendingSince
    }

    /// Nothing worth keeping: never seen, not queued.
    public var isBlank: Bool { seenAt == nil && pendingSince == nil }
}
