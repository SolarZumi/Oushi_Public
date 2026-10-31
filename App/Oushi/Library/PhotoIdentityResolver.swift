// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import CloudKit
import Foundation
import OushiCore
import Photos

/// Where the review keeps its store: the app's Application Support folder.
enum ReviewStorage {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Oushi", isDirectory: true)
    static let cloudContainerID = AppIdentity.cloudContainerID
}

/// PhotoKit's two identifier directories, asked off the main thread (they block on the Photos database).
struct PhotoKitIdentityResolver: PhotoIdentityResolving {
    func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for (id, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids) {
                if case .success(let cloudID) = result { found[id] = cloudID.stringValue }
            }
            return found
        }.value
    }

    func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            let cloudIDs = ids.map(PHCloudIdentifier.init(stringValue:))
            for (cloudID, result) in PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIDs) {
                if case .success(let id) = result { found[cloudID.stringValue] = id }
            }
            return found
        }.value
    }
}

/// Whether an iCloud account is signed in, as CloudKit answers.
struct CloudKitAccounts: CloudAccountChecking {
    let containerID: String

    func hasAccount() async -> Bool? {
        guard let status = try? await CKContainer(identifier: containerID).accountStatus() else { return nil }
        switch status {
        case .available: return true
        case .noAccount, .restricted: return false
        // Could not be asked right now (no network, the account temporarily unavailable): not a no.
        default: return nil
        }
    }
}
