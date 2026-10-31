// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation

/// The app's identity as App/Config/Identity.xcconfig sets it, read from Info.plist: the iCloud container the review
/// history syncs through and the website the About page links to. The public repository ships placeholders there.
enum AppIdentity {
    static let cloudContainerID = value(for: "OushiCloudContainer")
    static let website = URL(string: "https://\(value(for: "OushiWebsite"))/")!

    private static func value(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("\(key) is missing from Info.plist: set it in App/Config/Identity.xcconfig")
        }
        return value
    }
}
