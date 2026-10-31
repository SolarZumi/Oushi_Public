// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos

/// What the deck shows on top, decided once by the review screen and read by everything that goes by it: the
/// bars' words and offers, what the pool grows out of, and the copy of a system card the pool carries.
enum TopCard: Equatable, Sendable {
    /// The library and the ledger are still being read.
    case loading
    case access(PHAuthorizationStatus)
    case lesson(Lesson)
    /// The welcome's words: nothing to grow a pool out of.
    case welcome
    case photo(String)
    /// The end of a batch: the pool's preview with its button.
    case summary
    case notice(Notice)

    /// The states in which a system card stands in the deck's place to say where things are.
    enum Notice: Equatable, Sendable {
        /// The library has no photos or videos.
        case emptyLibrary
        /// Every photo and video has been seen (the pool's on their way in), the batch just done being the last,
        /// or no batch being possible because everything is in the pool.
        case everythingSeen
    }

    var photoID: String? {
        if case .photo(let id) = self { return id }
        return nil
    }

    /// A system card: a lesson, the access card, a notice. The pool grows out of a copy of it.
    var isSystemCard: Bool {
        switch self {
        case .access, .lesson, .notice: true
        case .loading, .welcome, .photo, .summary: false
        }
    }
}
