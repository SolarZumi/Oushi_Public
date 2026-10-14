// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Presents UIKit screens SwiftUI has no API for (the limited-library picker) from the view that
/// asked, through a view controller placed in that view's hierarchy, rather than by searching the window for its
/// top controller.
@MainActor
final class UIKitPresenter {
    fileprivate weak var anchor: UIViewController?

    func presentLimitedLibraryPicker() {
        guard let anchor else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: anchor)
    }
}

extension View {
    /// Places `presenter`'s anchor in this view's hierarchy.
    func presentationAnchor(_ presenter: UIKitPresenter) -> some View {
        background(PresentationAnchor(presenter: presenter).frame(width: 0, height: 0))
    }
}

private struct PresentationAnchor: UIViewControllerRepresentable {
    let presenter: UIKitPresenter

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        presenter.anchor = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        presenter.anchor = controller
    }
}
