// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// Loads one library photo at the given point size and hands it to `content`, keeping the old image while a
/// newer version loads. A card coming back (undo) is a new view with no image yet; the cache usually still has it.
struct PhotoLoading<Content: View>: View {
    let id: String
    let size: CGSize
    /// Fitted inside `size` (the deck's cards) or filling it (the pool's square cells): requested so from
    /// PhotoKit, so a filled square is not a fitted image stretched up.
    var contentMode: PHImageContentMode = .aspectFit
    /// Whose store the image goes into once loaded.
    var store: PhotoImageLoader.Store = .deck
    /// Bumped to try again after a failure.
    var attempt = 0
    /// Told whether the load has failed, each time that changes, for whoever shows the card around this.
    var onFailure: ((Bool) -> Void)? = nil
    @ViewBuilder let content: (_ image: UIImage?, _ failed: Bool) -> Content

    @Environment(PhotoLibrary.self) private var library
    @Environment(PhotoImageLoader.self) private var images
    @Environment(\.displayScale) private var displayScale
    /// The loaded image with the photo it is of (a reused view asked for another photo does not show the old
    /// one), and whether it is only PhotoKit's quick version while the real one is on its way.
    @State private var loaded: (id: String, image: UIImage, isPreview: Bool)?
    @State private var failed = false

    private var image: UIImage? { loaded?.id == id ? loaded?.image : nil }

    private var pixelSize: CGSize {
        CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    private var loadKey: String {
        let modified = library.asset(for: id)?.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(id)-\(Int(size.width))x\(Int(size.height))-\(modified)-\(attempt)"
    }

    var body: some View {
        content(image ?? images.cachedImage(for: id, targetSize: pixelSize, contentMode: contentMode), failed)
            .task(id: loadKey) {
                guard size.width > 0, size.height > 0 else { return }
                setFailed(false)
                let result = await images.image(for: id, targetSize: pixelSize, contentMode: contentMode, store: store) { preview in
                    // Something to look at while the real image comes (from iCloud, perhaps); never over a real one.
                    if loaded == nil || loaded?.id != id || loaded?.isPreview == true { loaded = (id, preview, true) }
                }
                guard !Task.isCancelled else { return }
                if let result {
                    loaded = (id, result, false)
                } else if image == nil || loaded?.isPreview == true {
                    // Nothing, or only the quick preview, which is not the photo: a failure, with its retry.
                    setFailed(true)
                }
            }
            .onDisappear { if failed { onFailure?(false) } }
    }

    private func setFailed(_ value: Bool) {
        guard failed != value else { return }
        failed = value
        onFailure?(value)
    }
}

/// Shows one library photo at the given point size as a SwiftUI image, for the pool's cells.
struct PhotoImage: View {
    let id: String
    let size: CGSize
    var contentMode: ContentMode = .fit

    @Environment(AppSettings.self) private var settings

    var body: some View {
        PhotoLoading(id: id, size: size, contentMode: contentMode == .fill ? .aspectFill : .aspectFit, store: .pool) { image, failed in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        // Photos with a gain map light up in HDR when the user wants them to; the image is redrawn
                        // the moment the switch moves.
                        .allowedDynamicRange(settings.photoHDR ? .high : .standard)
                        .id(settings.photoHDR)
                } else if failed {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }
}

/// The largest size with the photo's aspect ratio that fits inside `bounds`.
func fittedPhotoSize(_ asset: PHAsset?, in bounds: CGSize) -> CGSize {
    guard let asset, asset.pixelWidth > 0, asset.pixelHeight > 0 else { return bounds }
    return fittedSize(aspectRatio: CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight), in: bounds)
}

/// The largest size with the given width-to-height ratio that fits inside `bounds`.
func fittedSize(aspectRatio ratio: CGFloat, in bounds: CGSize) -> CGSize {
    guard ratio > 0, bounds.width > 0, bounds.height > 0 else {
        return CGSize(width: max(bounds.width, 0), height: max(bounds.height, 0))
    }
    let width = min(bounds.width, bounds.height * ratio)
    return CGSize(width: width, height: width / ratio)
}
