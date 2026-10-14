// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Foundation
import os

/// The app's loggers, one per area, so a problem can be followed in Console by subsystem and category.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "Oushi"
    static let library = Logger(subsystem: subsystem, category: "library")
    static let images = Logger(subsystem: subsystem, category: "images")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let background = Logger(subsystem: subsystem, category: "background")
}
