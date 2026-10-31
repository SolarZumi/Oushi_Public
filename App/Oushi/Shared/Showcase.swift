// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import ImageIO
import Photos
import SwiftUI

#if targetEnvironment(simulator)
/// Poses for App Store screenshots, simulator only: launched with `-showcase <pose>` (and `-showcasePhoto <part of
/// a file name>` for the photo on top), the app skips the lessons, clears what earlier poses left in the ledger,
/// starts a batch with that photo first and holds the deck in the pose, so a screenshot taken a moment later
/// always shows the same thing.
enum Showcase {
    enum Pose: String {
        /// The deck at rest.
        case idle
        /// The top card part way out to the left, the next one coming up.
        case swipeLeft
        /// The top card pulled down past the arming point, the ground gone red.
        case pullDown
        /// The top card at rest, its heart filled.
        case favorite
        /// The batch all pulled down: the summary card at the end, its grid full of queued photos.
        case summary
    }

    static let pose: Pose? = UserDefaults.standard.string(forKey: "showcase").flatMap(Pose.init)
    static let photoName: String? = UserDefaults.standard.string(forKey: "showcasePhoto")
    /// A folder of JPEGs on the Mac (`-showcaseLibrary <path>`; the simulator reads the Mac's files, though not
    /// under the folders macOS guards, such as Documents): the demo photos, which the app itself puts into the
    /// simulator's photo library on launch, so no `simctl addmedia` is needed and a freshly erased simulator
    /// works at once.
    static let libraryFolder: String? = UserDefaults.standard.string(forKey: "showcaseLibrary")

    /// The asset whose original file name contains `photoName`.
    @MainActor
    static func photoID(in library: PhotoLibrary) -> String? {
        guard let photoName else { return nil }
        return availableNames(in: library).first { $0.name.localizedCaseInsensitiveContains(photoName) }?.id
    }

    /// The library's photos that came from the showcase folder, in the library's order; the simulator's own
    /// sample photos are left out of the deck, so only the demo photos are in the store images. Nil when no
    /// folder was given.
    @MainActor
    static func shownIDs(in library: PhotoLibrary) -> [String]? {
        guard let libraryFolder else { return nil }
        let folder = URL(fileURLWithPath: libraryFolder)
        let names = Set(((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent))
        let shown = Set(availableNames(in: library).filter { names.contains($0.name) }.map(\.id))
        return library.availableIDs.filter(shown.contains)
    }

    /// Every available asset with its original file name.
    @MainActor
    private static func availableNames(in library: PhotoLibrary) -> [(id: String, name: String)] {
        library.availableIDs.flatMap { id -> [(id: String, name: String)] in
            guard let asset = library.asset(for: id) else { return [] }
            return PHAssetResource.assetResources(for: asset).map { (id: id, name: $0.originalFilename) }
        }
    }

    /// Adds the folder's JPEGs the library does not have yet (by original file name). Each gets a made-up date,
    /// so no real capture date shows in the store images: a random day since 2010, at a time of day that suits
    /// the picture (see `timeOfDay`). The days are handed out in the order the photos were really taken, so the
    /// deck (the cards behind the one on top, the summary's grid) is the same as it would be with their own
    /// dates; the random numbers come from a fixed seed, so every capture, on every device, has the same dates.
    /// Returns whether anything was added.
    @MainActor
    static func importLibrary(into library: PhotoLibrary) async -> Bool {
        guard let libraryFolder, library.hasAccess else { return false }
        let folder = URL(fileURLWithPath: libraryFolder)
        let present = Set(availableNames(in: library).map(\.name))
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && !present.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        Log.library.info("showcase: \(files.count, privacy: .public) photos to import from \(libraryFolder, privacy: .public)")
        guard !files.isEmpty else { return false }
        let taken = files.sorted { (captureDate(of: $0) ?? .distantPast) < (captureDate(of: $1) ?? .distantPast) }
        let dated = Array(zip(taken, madeUpDates(for: taken))).map { (file: $0, date: $1) }
        do {
            // PhotoKit runs the block on its own queue: not main-actor isolated, or the executor check traps.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                for (file, date) in dated {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.lastPathComponent
                    request.addResource(with: .photo, fileURL: file, options: options)
                    request.creationDate = date
                }
            }
        } catch {
            Log.library.error("showcase import failed: \(error, privacy: .public)")
        }
        return true
    }

    /// Made-up dates for `files`, oldest first: distinct random days from 2010 through 2025, each at a random
    /// minute within the photo's time of day, in the device's time zone.
    private static func madeUpDates(for files: [URL]) -> [Date] {
        // The background's seeded generator: the same numbers for the same seed, on every run.
        var random = SeededRandom(seed: "showcase dates")
        let calendar = Calendar.current
        let first = calendar.date(from: DateComponents(year: 2010, month: 1, day: 1))!
        let last = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        let span = calendar.dateComponents([.day], from: first, to: last).day!
        var days = Set<Int>()
        while days.count < files.count { days.insert(Int(random.next(in: 0...Double(span)).rounded())) }
        return zip(days.sorted(), files).map { day, file in
            let hours = timeOfDay(file.lastPathComponent)
            let minute = hours.lowerBound * 60 + Int(random.next(in: 0...Double((hours.upperBound - hours.lowerBound) * 60 - 1)))
            let date = calendar.date(byAdding: .day, value: day, to: first)!
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)!
        }
    }

    /// The hours a photo's made-up time falls in, by what its file name says it shows: sunset and dusk in the
    /// evening, the moon at night, everything else in the day.
    private static func timeOfDay(_ name: String) -> Range<Int> {
        if name.contains("月亮") || name.contains("夜") { return 20..<23 }
        if name.contains("夕阳") || name.contains("暮色") || name.contains("黄昏") { return 17..<19 }
        return 9..<16
    }

    /// When the photo was taken, for its place in the order only: EXIF DateTimeOriginal, read in its
    /// OffsetTimeOriginal when present and in the device's time zone when not; failing that, the file's
    /// modification date.
    private static func captureDate(of file: URL) -> Date? {
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
                if let date = formatter.date(from: original + offset) { return date }
            }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = .current
            if let date = formatter.date(from: original) { return date }
        }
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
#endif
