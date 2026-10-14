// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import Photos
import SwiftUI

/// Hosts the review screen, keeps the session in step with the library and the settings, and shows what went
/// wrong in either.
struct RootView: View {
    /// The deck and the pool, made once with the other models: a model made in a view's `init` is made again on
    /// every update of the view above it and thrown away, and one that runs an observation loop would run on.
    let deck: CardDeck
    let pool: PoolController

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewSession.self) private var review
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Always the review screen: without access it shows the access card on top of the deck.
        ReviewScreen(review: review, deck: deck, pool: pool)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // The last moves go to disk now, in case the app is ended before their write gets its turn.
                BackgroundWork.run(named: "oushi.ledger-write") { await review.flush() }
            }
            guard phase == .active else { return }
            library.refresh()
            review.retryWrites()
            synchronize()
        }
        .onChange(of: library.availableIDs) { synchronize() }
        .onChange(of: library.hasLoaded) { synchronize() }
        .onChange(of: library.isReading) { synchronize() }
        .onChange(of: review.isLoaded) { synchronize() }
        .onChange(of: settings.batchSize) { review.setBatchSize(settings.batchSize) }
        .onChange(of: settings.order) { review.setOrder(settings.order) }
        .onChange(of: settings.iCloudSync) { _, enabled in
            // Cannot be turned on (no iCloud account): the switch goes back off.
            Task {
                let isOn = await review.setCloudSync(enabled)
                if enabled, !isOn { settings.iCloudSync = false }
            }
        }
        // Found at launch to have no account to sync with: the switch follows.
        .onChange(of: review.syncState) { _, state in
            if state == .stalled("account"), settings.iCloudSync { settings.iCloudSync = false }
        }
        .alert("未能完成", isPresented: Binding(
            get: { review.issues.first != nil || library.errorMessage != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            Button("好", role: .cancel) { clearErrors() }
        } message: {
            Text(review.issues.first?.message ?? library.errorMessage ?? String(localized: "请稍后重试。"))
        }
    }

    /// Only once both the library and the ledger have been read: before that, no photos means "not known yet",
    /// and syncing would empty the saved batch or let go of records that are not loaded yet.
    private func synchronize() {
        guard library.hasAccess, library.hasLoaded, !library.isReading, review.isLoaded else { return }
        var availableIDs = library.availableIDs
        #if targetEnvironment(simulator)
        // Screenshots: only the demo photos, not the simulator's sample ones.
        if let shown = Showcase.shownIDs(in: library) { availableIDs = shown }
        #endif
        review.synchronize(availableIDs: availableIDs, hasFullAccess: library.hasFullAccess)
    }

    private func clearErrors() {
        if let issue = review.issues.first { review.dismiss(issue) }
        library.clearError()
    }
}

extension ReviewIssue {
    /// The issue in the user's words.
    var message: String {
        switch self {
        case .ledgerUnreadable: String(localized: "之前的整理记录暂时无法读取。")
        case .ledgerNotPersistent: String(localized: "整理记录暂时无法保存到本机，这次的记录在退出后会丢失。")
        case .saveFailed: String(localized: "整理记录暂时无法保存，请重试。")
        case .cloudNeedsAccount: String(localized: "iCloud 同步暂时无法开启，请确认已登录 iCloud。")
        }
    }
}

/// Work that must finish after the app has left the foreground, under a background task that is ended when the
/// work is done or when the system's time for it runs out.
@MainActor
enum BackgroundWork {
    @MainActor private final class Ticket {
        var identifier = UIBackgroundTaskIdentifier.invalid
        var task: Task<Void, Never>?

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    static func run(named name: String, _ work: @escaping @MainActor () async -> Void) {
        let ticket = Ticket()
        ticket.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            ticket.task?.cancel()
            ticket.end()
        }
        ticket.task = Task {
            await work()
            ticket.end()
        }
    }
}
