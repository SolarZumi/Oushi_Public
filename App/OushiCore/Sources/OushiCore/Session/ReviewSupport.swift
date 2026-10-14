// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// PhotoKit's two directories, behind a protocol so the session can be tested without a photo library.
public protocol PhotoIdentityResolving: Sendable {
    /// iCloud Photos identifiers by local identifier; photos iCloud does not know are left out.
    func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String]
    /// Current local identifiers by iCloud identifier; photos not on this device are left out.
    func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String]
}

/// Whether there is an iCloud account to sync with.
public protocol CloudAccountChecking: Sendable {
    /// True or false when known; nil when the question could not be answered right now (no network).
    func hasAccount() async -> Bool?
}

/// Something the user should know about the review's records. The session keeps the ones that stand; the app
/// puts them into words.
public enum ReviewIssue: Equatable, Hashable, Sendable, Identifiable {
    /// The store opened but could not be read: what was there is not shown, and is not written over.
    case ledgerUnreadable
    /// The store could not be opened: the review works for this run in memory, and nothing is kept.
    case ledgerNotPersistent
    /// Writing keeps failing; the changes are held in memory and tried again when the app comes back.
    case saveFailed
    /// Sync was asked for but there is no iCloud account to sync with.
    case cloudNeedsAccount

    public var id: Self { self }
}

/// Where the copy in iCloud stands.
public enum SyncState: Equatable, Sendable {
    case off
    case on
    /// Mirroring is set up but nothing will move: no account, or the last attempt failed for the reason given.
    case stalled(String)
}
