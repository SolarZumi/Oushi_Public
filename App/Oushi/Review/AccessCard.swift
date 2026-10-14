// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import Photos
import SwiftUI

/// The card on top of the deck while the app may not read the library: before the user has answered, a line and
/// the button that asks; refused, the warning and the way to Settings; restricted, the warning alone. It cannot be
/// swiped away.
struct AccessCard: View {
    let status: PHAuthorizationStatus
    /// Size of the area the deck lays cards out in.
    let bounds: CGSize
    let requestAccess: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let compact = CardShape.isCompact(bounds)
        SystemCard(bounds: bounds) {
            VStack(spacing: compact ? 10 : 20) {
                Spacer(minLength: 0)
                Image(systemName: status == .notDetermined ? "photo.on.rectangle.angled" : "photo.badge.exclamationmark")
                    .font(.system(size: compact ? 32 : 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                if let action {
                    Button(action: action.run) {
                        Text(action.title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .modifier(GlassPillButton())
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch status {
        case .notDetermined: String(localized: "需要访问相册")
        default: String(localized: "无法访问照片和视频")
        }
    }

    /// Before the user has answered, what comes next and what the app does with the photos: the system prompt
    /// is where the choice is made, so the button only goes on (App Review 5.1.1(iv)). Refused or restricted, why
    /// nothing shows.
    private var detail: String? {
        switch status {
        case .notDetermined: String(localized: "接下来系统会询问是否允许访问照片。偶拾不会上传你的照片，删除前也都会先经过你确认。")
        case .restricted: String(localized: "这台设备限制了对照片的访问。")
        default: String(localized: "请在“设置”中允许偶拾访问照片")
        }
    }

    private var action: (title: String, run: () -> Void)? {
        switch status {
        case .notDetermined:
            // Neutral, never "allow": the choice is the system prompt's, not this button's.
            (String(localized: "继续"), requestAccess)
        case .restricted:
            nil
        default:
            (String(localized: "前往设置"), { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } })
        }
    }
}
