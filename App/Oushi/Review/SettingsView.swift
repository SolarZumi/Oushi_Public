// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import SwiftUI

/// The app's settings. Each row names the setting on the left and holds its menu or switch on the right; the last
/// row leads to the About page.
struct SettingsView: View {
    let review: ReviewSession

    @Environment(AppSettings.self) private var settings
    @Environment(OnboardingFlow.self) private var onboarding
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReset = false

    @Environment(\.openURL) private var openURL

    /// The language the app is running in, named in that language.
    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        return Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    Picker("每组数量", selection: $settings.batchSize) {
                        ForEach(ReviewSession.batchSizes, id: \.self) { size in
                            Text("\(size) 项").tag(size)
                        }
                        Text("无限").tag(ReviewSession.unlimitedBatchSize)
                    }
                    Picker("回顾顺序", selection: $settings.order) {
                        ForEach(ReviewOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }
                // The chosen values read as text, not as links.
                .tint(.primary)
                Section {
                    Toggle("震动反馈", isOn: $settings.hapticsEnabled)
                    Toggle("照片 HDR", isOn: $settings.photoHDR)
                    Toggle("视频 HDR", isOn: $settings.videoHDR)
                }
                Section {
                    Button("重新查看教程") {
                        onboarding.restart()
                        dismiss()
                    }
                    .tint(.primary)
                    Button("重置进度", role: .destructive) { confirmsReset = true }
                        .confirmationDialog("重置进度", isPresented: $confirmsReset, titleVisibility: .visible) {
                            Button("重置", role: .destructive) { review.resetProgress() }
                        } message: {
                            Text("重置进度将会还原所有查看记录，媒体可能重复出现。待删除的内容会保留。")
                        }
                }
                Section {
                    Toggle("iCloud 同步浏览记录", isOn: $settings.iCloudSync)
                }
                Section {
                    // The app's language is chosen in the Settings app; this opens the app's page there.
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        LabeledContent("语言") {
                            HStack(spacing: 6) {
                                Text(currentLanguageName)
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                    }
                    .tint(.primary)
                }
                Section {
                    NavigationLink("关于") { AboutView() }
                }
                #if DEBUG
                // The review screen's end states on demand, for looking at them. Orange, debug wording, not localized.
                Section {
                    ForEach(AppSettings.StateTest.allCases) { test in
                        Button {
                            settings.stateTest = test
                            dismiss()
                        } label: {
                            HStack {
                                Text(verbatim: test.title)
                                Spacer()
                                if settings.stateTest == test { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if settings.stateTest != nil {
                        Button {
                            settings.stateTest = nil
                            dismiss()
                        } label: {
                            Text(verbatim: "退出测试")
                        }
                    }
                } header: {
                    Text(verbatim: "测试")
                }
                .tint(.orange)
                .foregroundStyle(.orange)
                #endif
            }
            .pickerStyle(.menu)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Closed from the top left, as the system's own full-screen settings are.
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Settings › About: the version, the app's pages on the web (support, the privacy policy, the terms of use), and the
/// open-source license.
struct AboutView: View {
    private static let support = AppIdentity.website.appending(path: "support/")
    private static let privacyPolicy = AppIdentity.website.appending(path: "privacy/")
    private static let terms = AppIdentity.website.appending(path: "terms/")

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        List {
            Section {
                LabeledContent("版本") {
                    Text(version).monospacedDigit()
                }
            }
            Section {
                webRow("技术支持", destination: Self.support)
                webRow("隐私政策", destination: Self.privacyPolicy)
                webRow("使用条款", destination: Self.terms)
            }
            Section {
                NavigationLink("开源许可") { OpenSourceLicenseView() }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A row that opens a web page, in the shape of the settings' language row: the name on the left, the
/// leaving-the-app mark on the right.
@MainActor
private func webRow(_ title: LocalizedStringKey, destination: URL) -> some View {
    Link(destination: destination) {
        LabeledContent(title) {
            Image(systemName: "arrow.up.forward.app")
        }
    }
    .tint(.primary)
}

/// Settings › About › Open Source License: the app's Appropriate Legal Notices under the GPL. ADDITIONAL-TERMS.md
/// requires distributed works to retain attribution. The license documents are read from the public repository, so
/// changes to them reach users at once; the copies bundled with the app stand in when the repository can't be reached.
struct OpenSourceLicenseView: View {
    private static let repository = URL(string: "https://github.com/SolarZumi/Oushi_Public")!

    var body: some View {
        List {
            Section {
                LabeledContent("原项目") {
                    Text(verbatim: "偶拾 (Oushi)")
                }
                LabeledContent("作者") {
                    Text(verbatim: "Zuming Hu")
                }
                Link(destination: Self.repository) {
                    LabeledContent {
                        Image(systemName: "arrow.up.forward.app")
                    } label: {
                        Text("源代码")
                        Text(verbatim: "github.com/SolarZumi/Oushi_Public")
                    }
                }
                .tint(.primary)
            }
            Section {
                NavigationLink {
                    LicenseDocumentView(title: "许可证", document: .license)
                } label: {
                    LabeledContent("许可证") {
                        Text(verbatim: "GNU GPL v3")
                    }
                }
                .tint(.primary)
                NavigationLink("附加条款") {
                    LicenseDocumentView(title: "附加条款", document: .additionalTerms)
                }
                NavigationLink("名称与图标") {
                    LicenseDocumentView(title: "名称与图标", document: .branding)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("代码采用 GNU GPL v3 及附加条款，你可以按这些条款再发布和修改。名称和图标另行授权。在法律允许的范围内，本软件不提供担保。")
                    Text(verbatim: "© 2026 Zuming Hu")
                }
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A license document at the root of the public repository, and the copy of it that Tools/sync_legal.py bundles with
/// the app (Tools/check.sh fails while the two differ, so a release always carries the current text).
private enum LicenseDocument: String {
    case license = "LICENSE"
    case additionalTerms = "ADDITIONAL-TERMS.md"
    case branding = "BRANDING.md"

    /// The file as GitHub shows it, for opening in the browser.
    var page: URL { URL(string: "https://github.com/SolarZumi/Oushi_Public/blob/main/\(rawValue)")! }

    /// The file's current text on the repository's main branch.
    private var source: URL { URL(string: "https://raw.githubusercontent.com/SolarZumi/Oushi_Public/main/\(rawValue)")! }

    private var bundledResource: String {
        switch self {
        case .license: "OushiLicense"
        case .additionalTerms: "OushiAdditionalTerms"
        case .branding: "OushiBranding"
        }
    }

    var bundled: String? {
        Bundle.main.url(forResource: bundledResource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The repository's text, or nil when it can't be had: no network, GitHub out of reach (as it often is from
    /// mainland China), or the repository not public yet. Never a cached copy, so an edit shows on the next visit.
    func fetch() async -> String? {
        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One license document, shown in the app. ADDITIONAL-TERMS.md and BRANDING.md are Markdown and the GPL is
/// hard-wrapped plain text; both are shown as paragraphs that wrap to the screen, the Markdown with its headings,
/// lists and inline styles drawn rather than spelled out.
private struct LicenseDocumentView: View {
    let title: LocalizedStringKey
    let document: LicenseDocument

    private enum Content {
        case loading
        case current([LicenseBlock])
        case bundled([LicenseBlock])
        /// Neither the repository nor a bundled copy: only an incorrectly packaged build gets here.
        case missing
    }

    @State private var content = Content.loading

    var body: some View {
        ScrollView {
            switch content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            case .current(let blocks):
                text(of: blocks)
            case .bundled(let blocks):
                VStack(alignment: .leading, spacing: 8) {
                    Label("无法连接仓库，以下是 App 内附带的版本。", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    text(of: blocks)
                }
            case .missing:
                Link(destination: document.page) {
                    Label(title, systemImage: "arrow.up.forward.app")
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: document.page) {
                    Label("在浏览器中打开", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .task {
            if let text = await document.fetch() {
                content = .current(LicenseBlock.blocks(of: text))
            } else if let text = document.bundled {
                content = .bundled(LicenseBlock.blocks(of: text))
            } else {
                content = .missing
            }
        }
    }

    private func text(of blocks: [LicenseBlock]) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                blocks[index]
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// One paragraph-level piece of a license document.
private enum LicenseBlock: View {
    case heading(AttributedString, level: Int)
    case paragraph(AttributedString)
    case item(AttributedString)
    case rule

    var body: some View {
        switch self {
        case .heading(let text, let level):
            Text(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, level == 1 ? 0 : 8)
        case .paragraph(let text):
            Text(text)
        case .item(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                Text(text)
            }
        case .rule:
            Divider().padding(.vertical, 8)
        }
    }

    /// The blocks of a document, read as Markdown when it opens with a Markdown heading and as the GPL's plain text
    /// otherwise. Paragraphs are separated by blank lines in both.
    static func blocks(of document: String) -> [LicenseBlock] {
        let paragraphs = document
            .components(separatedBy: .newlines)
            .split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        return document.hasPrefix("#")
            ? paragraphs.flatMap(markdownBlocks)
            : paragraphs.map(plainTextBlock)
    }

    private static func markdownBlocks(_ lines: [String]) -> [LicenseBlock] {
        if lines == ["---"] { return [.rule] }
        if lines.count == 1, let heading = lines[0].firstMatch(of: /^(#{1,6})\s+(.+)$/) {
            return [.heading(inline(String(heading.2)), level: heading.1.count)]
        }
        if lines.allSatisfy({ $0.hasPrefix("- ") }) {
            return lines.map { .item(inline(String($0.dropFirst(2)))) }
        }
        // The address lines at the top of each file are separate lines in one paragraph; keep them apart.
        return [.paragraph(inline(lines.joined(separator: "\n")))]
    }

    /// A paragraph of the GPL, its hard wraps joined. The section titles ("0. Definitions."), the all-capital headings
    /// ("TERMS AND CONDITIONS") and the plain ones ("Preamble") stand alone and are set as headings.
    private static func plainTextBlock(_ lines: [String]) -> LicenseBlock {
        let text = lines.joined(separator: " ")
        let isTitle = text.count < 80
            && (text == text.uppercased()
                || text.wholeMatch(of: /\d+\. [^.]+\./) != nil
                || text.allSatisfy { $0.isLetter || $0 == " " })
        return isTitle ? .heading(AttributedString(text), level: 3) : .paragraph(AttributedString(text))
    }

    /// Bold, italics and code drawn; links to files in the repository dropped, as there is no repository to go to
    /// here, and links to web addresses kept.
    private static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var text = try? AttributedString(markdown: markdown, options: options) else { return AttributedString(markdown) }
        for run in text.runs where run.link?.scheme == nil && run.link != nil {
            text[run.range].link = nil
        }
        return text
    }
}

extension ReviewOrder {
    var title: String {
        switch self {
        case .random: String(localized: "随机")
        case .newest: String(localized: "从最近开始")
        case .oldest: String(localized: "从最老开始")
        }
    }
}
