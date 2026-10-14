// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

import OushiCore
import Photos
import SwiftUI

/// The screen the app opens on: the card deck over the photo-lit ground, the navigation bar (settings, the
/// archive), the bottom bar (favorite, progress, undo), and the deletion pool that grows out of the card on top.
///
/// This view reads only what changes per photo. Per-frame drag state lives in `CardDeck` and is read by the deck,
/// the progress capsule and the background, so a drag does not redraw the bars. What is on top is decided once,
/// as `topCard`, and everything else here goes by it.
struct ReviewScreen: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(PhotoImageLoader.self) private var images
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    let deck: CardDeck
    let pool: PoolController
    @State private var layout = ReviewLayout()
    @State private var presenter = UIKitPresenter()
    /// The room between the bars, in screen coordinates: for the pool's cell size, and for the pool's overlay,
    /// which runs under the bars.
    @State private var contentFrame: CGRect = .zero
    /// The deck's room as the screen's own cards (the summary, the completion card) use it, taken over a turn of
    /// the run loop after it changes, for the reason given in CardDeckView.
    @State private var cardRoom: CGSize = .zero
    /// Restore was tapped: the system asks whether to, as it does before deleting. The photos asked about are
    /// fixed then: what joins the pool meanwhile (from another device) is not restored unasked.
    @State private var confirmsRestore = false
    @State private var restoreTargets: [String] = []
    /// 重置浏览进度 was tapped on the progress capsule: an alert in the middle of the screen asks before the progress
    /// is reset.
    @State private var confirmsStartOver = false
    @State private var showsSettings = false

    private let review: ReviewSession

    init(review: ReviewSession, deck: CardDeck, pool: PoolController) {
        self.review = review
        self.deck = deck
        self.pool = pool
    }

    private var batch: ReviewBatch { review.batch }
    private var currentAsset: PHAsset? { deck.currentID.flatMap(library.asset(for:)) }
    private var pendingCount: Int { review.pendingCount }

    var body: some View {
        NavigationStack {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contentFrame = $0 }
                // Under the bars, so their buttons stay on top while the card fills the screen beneath them. The
                // card on top reports where it is through an anchor; the overlay resolves it in its own space, so
                // the pool grows from exactly there and follows it as the deck is laid out again.
                .overlayPreferenceValue(TopCardAnchor.self) { anchor in
                    if pool.isPresented {
                        PoolOverlay(
                            pool: pool,
                            // Only the card the pool grew out of: the deck may move on underneath meanwhile.
                            origin: topCard == pool.source ? anchor : nil,
                            contentFrame: contentFrame,
                            isLimitedAccess: library.authorizationStatus == .limited,
                            imageSide: poolImageSide,
                            actions: poolActions
                        ) {
                            systemCard(pool.source, in: cardRoom == .zero ? deck.size : cardRoom)
                        }
                    }
                }
                // Out of the foreground every card, the pool included, hides what it shows under the card color.
                .environment(\.cardsCovered, deck.isCovered)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        // The photo-lit ground is always dark, so the bars and text on it are too. The settings screen sets its own.
        .environment(\.colorScheme, .dark)
        .presentationAnchor(presenter)
        // The settings fill the screen on a phone; on a wide screen (an iPad) they come up as a form sheet in the
        // middle of it, as the system's own do, rather than take the whole display.
        .fullScreenCover(isPresented: settingsPresented(when: .compact)) {
            SettingsView(review: review)
        }
        .sheet(isPresented: settingsPresented(when: .regular)) {
            SettingsView(review: review)
                .presentationSizing(.form)
        }
        // On the screen, not on the capsule that asks for it: presented from a glass button an alert grows out of
        // it, and the capsule (glass of its own, not the bar's) is no source the system can grow anything from.
        // From here it comes up in the middle of the screen as any alert does, and the capsule stays as it is.
        .alert(Text("重置浏览进度？"), isPresented: $confirmsStartOver) {
            Button("取消", role: .cancel) {}
            Button("重置进度", role: .destructive, action: startOver)
        } message: {
            Text("这将清除所有浏览记录。已查看的照片和视频会重新出现，待删除的内容会保留。")
        }
        // Access granted (or lost) while on screen: the access card goes or comes; the lessons wait beneath.
        .onChange(of: library.hasAccess, initial: true) { _, hasAccess in
            withAnimation(Motion.cardChange) { deck.hasLibraryAccess = hasAccess }
        }
        #if targetEnvironment(simulator)
        .task(id: library.hasLoaded && review.isLoaded) {
            guard let pose = Showcase.pose, library.hasLoaded, review.isLoaded else { return }
            // The demo photos go into the simulator's library first, if they are not there yet; the library's
            // observer brings them into the deck, which gets a moment to take them in.
            if await Showcase.importLibrary(into: library) {
                try? await Task.sleep(for: .seconds(2))
            }
            // The library and the batch settle first; then the pose is set and the images get a moment to arrive.
            try? await Task.sleep(for: .seconds(0.6))
            // A clean ledger each launch: the summary pose queues a whole batch, and the poses after it would
            // otherwise find those photos gone from the deck.
            review.removeFromPool(ids: Array(review.pendingIDs))
            review.resetProgress()
            // Newest first, so the card behind the chosen one is the same in every capture. A batch of 15: the
            // count the capsule shows, and for the summary pose all 15 queued, which leaves photos outside the
            // pool so the batch ends on the summary card (with nothing left it would end on 所有内容都看过了).
            settings.order = .newest
            review.setOrder(.newest)
            settings.batchSize = 15
            review.setBatchSize(settings.batchSize)
            review.startNextBatch(first: Showcase.photoID(in: library))
            try? await Task.sleep(for: .seconds(0.4))
            switch pose {
            case .idle: break
            case .swipeLeft: deck.hold(offset: CGSize(width: -deck.size.width * 0.36, height: 0), armed: false)
            case .pullDown: deck.hold(offset: CGSize(width: 0, height: deck.holdDistance + 56), armed: true)
            case .favorite: break
            case .summary:
                // Every card pulled down: the batch ends on the summary card over a pool of 15.
                while review.advance(delete: true, direction: .down) {}
            }
        }
        #endif
        // The pool's first screens stay decoded, so the card can grow into the pool without photos filling in.
        .task(id: WarmKey(ids: pool.firstScreen, side: poolImageSide)) {
            guard poolImageSide > 0 else { return }
            let side = poolImageSide * displayScale
            await images.warm(pool.firstScreen, targetSize: CGSize(width: side, height: side))
        }
        .onChange(of: scenePhase) { _, phase in
            // The cover goes on as soon as the scene stops being active (the swipe toward the app switcher starts
            // there, while the screen is still showing), so the switcher's snapshot never has a photo in it.
            // In-flight cards are dropped only once truly in the background.
            switch phase {
            case .active: deck.uncover()
            // The system's own deletion confirmation may take the scene inactive; the pool stays readable then.
            case .inactive: if !pool.isDeleting { deck.cover() }
            case .background:
                deck.cover(animated: false)
                deck.reset()
            @unknown default: break
            }
        }
    }

    /// The settings' presentation for one width class: shown there while the width is that, and closed from
    /// either presentation.
    private func settingsPresented(when wanted: UserInterfaceSizeClass) -> Binding<Bool> {
        Binding(
            get: { showsSettings && (sizeClass ?? .compact) == wanted },
            set: { if !$0 { showsSettings = false } }
        )
    }

    private struct WarmKey: Equatable {
        var ids: [String]
        var side: CGFloat
    }

    // MARK: What is on top

    /// The one decision everything here goes by: what the deck shows on top right now.
    private var topCard: TopCard {
        if let stateTest {
            switch stateTest {
            case .emptyLibrary: return .notice(.emptyLibrary)
            case .batchDone: return .summary
            case .everythingSeenWithPool, .everythingSeenEmptyPool: return .notice(.everythingSeen)
            }
        }
        // The saved batch's photos are not looked up yet; showing cards now would flash load errors.
        guard library.hasLoaded, review.isLoaded else { return .loading }
        switch deck.phase {
        case .needsAccess: return .access(library.authorizationStatus)
        case .lesson(let lesson): return .lesson(lesson)
        case .welcome: return .welcome
        case .reviewing:
            if let id = deck.currentID { return .photo(id) }
            if batch.isComplete { return review.isEverythingSeen ? .notice(.everythingSeen) : .summary }
            // No batch could be made: the library is empty, or everything in it is in the pool.
            return .notice(review.availableCount == 0 ? .emptyLibrary : .everythingSeen)
        }
    }

    private var stateTest: AppSettings.StateTest? {
        #if DEBUG
        settings.stateTest
        #else
        nil
        #endif
    }

    // MARK: Content

    /// The deck's room is read from a GeometryReader, which takes exactly what the navigation stack offers and
    /// never grows with its contents, and handed to the deck and its cards in the same pass, so the first frame
    /// is laid out at the right size. Measured off the deck itself, the room fed back on itself: cards are sized
    /// from the room, a stack sizes itself to its cards, and once the phone turned sideways the cards kept the
    /// old height, the stack kept the cards' height, and the room never shrank.
    private var content: some View {
        GeometryReader { proxy in
            let room = deckRoom(proposed: proxy.size)
            let bounds = cardRoom == .zero ? room : cardRoom
            let top = topCard
            ZStack {
                if stateTest != nil {
                    // Debug: one of the end states, in the deck's place.
                    standaloneCard(top, in: bounds)
                } else if top == .loading {
                    ProgressView()
                } else {
                    // A notice in the deck's place: the library's own state, nothing on top and nothing finished
                    // (a finished batch shows its notice as the deck's own summary card).
                    if case .notice = top, !batch.isComplete {
                        standaloneCard(top, in: bounds)
                    }
                    // One deck through every state, so cards keep their views (and a video its sound) across the
                    // access card coming and going.
                    CardDeckView(
                        deck: deck, layout: layout, room: room, summary: summaryInDeck(in: bounds),
                        hiddenPhotoID: pool.isPresented ? pool.source.photoID : nil,
                        isObscured: pool.isPresented || showsSettings,
                        hidesSystemCards: pool.isPresented && pool.source.isSystemCard
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: room, initial: true) { _, size in
                Task { @MainActor in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { cardRoom = size }
                }
            }
        }
        // The pool fills the screen: what is under it is out of reach for assistive technology too.
        .accessibilityHidden(pool.isExpanded)
        .background { AmbientBackground(deck: deck, isHidden: pool.phase == .open) }
    }

    /// A card drawn by the screen itself, in the deck's place: it says where it is, as the deck's top card does, so
    /// the pool can grow out of it.
    private func standaloneCard(_ top: TopCard, in bounds: CGSize) -> some View {
        systemCard(top, in: bounds)
            .anchorPreference(key: TopCardAnchor.self, value: .bounds) { $0 }
            .opacity(pool.isPresented ? 0 : 1)
    }

    /// The room the deck lays its cards out in: what the navigation stack offers (the bars are in its safe area),
    /// less the margins. Nothing else caps it: a cap taken from the screen's bounds would lag a rotation, which
    /// changes the bounds only once its animation is over, and hold the cards at the old size until then.
    private func deckRoom(proposed: CGSize) -> CGSize {
        CGSize(width: max(proposed.width - 24, 0), height: max(proposed.height - 16, 0))
    }

    /// The card at the end of a batch, as the deck's summary item: the pool's preview with its button, or, once
    /// everything has been seen, the notice saying so. Hidden while the pool overlay stands in for it, so there
    /// is one card on screen.
    @ViewBuilder
    private func summaryInDeck(in room: CGSize) -> some View {
        systemCard(review.isEverythingSeen ? .notice(.everythingSeen) : .summary, in: room)
            .opacity(pool.isPresented ? 0 : 1)
    }

    /// A card for what is on top, drawn in the deck's place or carried by the pool as the copy it grows out of:
    /// the access card, a lesson, a notice, the summary. The one drawing of each, wherever it is shown.
    @ViewBuilder
    private func systemCard(_ top: TopCard, in room: CGSize) -> some View {
        switch top {
        case .access(let status):
            AccessCard(status: status, bounds: room) {}
        case .lesson(let lesson):
            TutorialCard(lesson: lesson, bounds: room)
        case .notice(let notice):
            noticeCard(notice, pendingCount: noticePendingCount, in: room)
        case .summary:
            SummaryCard(
                bounds: room,
                pendingIDs: pool.pendingIDs,
                isLimitedAccess: library.authorizationStatus == .limited,
                imageSide: poolImageSide,
                check: openPool,
                chooseMorePhotos: { presenter.presentLimitedLibraryPicker() }
            )
        case .loading, .welcome, .photo:
            EmptyView()
        }
    }

    /// The count the everything-seen notice shows: the pool's, or, under a debug state, a few for looks.
    private var noticePendingCount: Int {
        switch stateTest {
        case .everythingSeenWithPool: max(pendingCount, 3)
        case .everythingSeenEmptyPool, .emptyLibrary: 0
        case .batchDone, nil: pendingCount
        }
    }

    /// A system card saying where things are. The empty library has its symbol, sentence and advice. Everything
    /// seen is the plainest: the sentence and the pool's button (or, with nothing in the pool, that there is
    /// nothing); starting over is the progress capsule's offer.
    private func noticeCard(_ notice: TopCard.Notice, pendingCount: Int, in room: CGSize) -> some View {
        let compact = CardShape.isCompact(room)
        return SystemCard(bounds: room) {
            VStack(spacing: compact ? 10 : 20) {
                Spacer(minLength: 0)
                switch notice {
                case .emptyLibrary:
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: compact ? 32 : 56, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("相册里没有照片和视频")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                    Text("拍了照片或视频之后再来看看。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                case .everythingSeen:
                    Text("所有内容都看过了")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    noticeButton(
                        pendingCount > 0 ? Text("检查 \(pendingCount) 项媒体").monospacedDigit() : Text("没有待删除媒体"),
                        action: openPool
                    )
                    .disabled(pendingCount == 0)
                }
                if library.authorizationStatus == .limited {
                    Button("选择更多照片") { presenter.presentLimitedLibraryPicker() }
                        .font(.subheadline)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func noticeButton(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .modifier(GlassPillButton())
    }

    /// Confirmed 重置进度: every "seen" mark goes and a fresh batch begins, so the deck turns from the notice to
    /// the first card of the batch in the chosen order. Under a state test, this only ends the test.
    private func startOver() {
        #if DEBUG
        if settings.stateTest != nil {
            settings.stateTest = nil
            return
        }
        #endif
        review.resetProgress()
    }

    // MARK: Bars

    /// Plain bar items throughout, placed and animated as the system does it. While the pool is open, each button
    /// turns into the pool's counterpart in its place: settings into 选择, the archive into 完成, the heart into
    /// 全部恢复, undo into 全部删除. The progress capsule in the middle of the bottom bar leaves while the pool is
    /// open, so the two words on either side have the room; the pool's title and count are in the bar above.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if pool.isExpanded {
                Button(action: pool.toggleSelecting) {
                    Text(pool.isSelecting ? String(localized: "取消") : String(localized: "选择"))
                }
                .disabled(pool.pendingIDs.isEmpty)
            } else {
                Button("设置", systemImage: "gearshape") { showsSettings = true }
            }
        }
        ToolbarItem(placement: .principal) { titleView }
        ToolbarItem(placement: .topBarTrailing) {
            if pool.isExpanded {
                Button("完成") { pool.dismiss() }
                    .fontWeight(.semibold)
                    // Tapped while the pool is still growing, the growth turns around at once.
            } else {
                Button("检查媒体", systemImage: "photo.stack", action: openPool)
                    .accessibilityLabel(String(localized: "检查媒体，\(pendingCount) 项"))
            }
        }
        ToolbarItem(placement: .bottomBar) { bottomLeading }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        // The capsule draws its own glass and stays out of the bar's shared one: a bar item that comes and goes
        // on the shared glass is split out of (and merged back into) the button beside it by the bar's own
        // transition, and SwiftUI offers no way to opt a bar item out of that. With no shared glass to morph,
        // the capsule dissolves in place both ways. While the pool is open its content is empty, leaving the
        // words at the ends the whole bar in every language.
        ToolbarItem(placement: .bottomBar) {
            if !pool.isExpanded {
                progressItem
                    .glassEffectTransition(.materialize)
                    .transition(.opacity)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { bottomTrailing }
    }

    @ViewBuilder
    private var bottomLeading: some View {
        if pool.isExpanded {
            Button {
                restoreTargets = pool.targets
                confirmsRestore = true
            } label: {
                Text(pool.isSelecting ? String(localized: "恢复") : String(localized: "全部恢复"))
            }
            .disabled(pool.targets.isEmpty || pool.isDeleting)
            // Confirmed the way a deletion is, in the system's own sheet.
            .confirmationDialog(
                Text("恢复 \(restoreTargets.count) 项？"),
                isPresented: $confirmsRestore,
                titleVisibility: .visible
            ) {
                Button("恢复") { pool.restore(restoreTargets) }
            } message: {
                Text("恢复后它们会移出待删除，留在相册里。")
            }
        } else {
            FavoriteButton(photoID: deck.currentID, pretendID: deck.systemCardID)
        }
    }

    @ViewBuilder
    private var bottomTrailing: some View {
        if pool.isExpanded {
            Button(role: .destructive) { pool.delete(pool.targets) } label: {
                Text(pool.isSelecting ? String(localized: "删除") : String(localized: "全部删除"))
            }
            .tint(.red)
            .disabled(pool.targets.isEmpty || pool.isDeleting)
        } else {
            // Available mid-drag too: undo takes the drag over. Not while the pool is still shrinking back onto
            // the deck: the card coming back would cross it.
            Button("撤销", systemImage: "arrow.uturn.backward") { deck.undo() }
                .disabled(!deck.canUndo || pool.isPresented)
        }
    }

    /// The progress capsule; the question 重置浏览进度 raises is the screen's (see the alert in `body`).
    private var progressItem: some View {
        BatchProgressCapsule(
            deck: deck,
            layout: layout,
            completion: capsuleCompletion,
            progress: review.isBatchUnlimited
                ? String(deck.positionInBatch)
                : String(localized: "第 \(deck.positionInBatch) 个，共 \(batch.ids.count) 个"),
            isUnlimited: review.isBatchUnlimited,
            startNextBatch: { deck.startNextBatch() },
            startOver: { confirmsStartOver = true }
        )
    }

    /// What the capsule offers once the batch is done or there is none (nil while a batch is under way, or while a
    /// lesson or the access card stands in): everything seen asks to start over; photos left outside the pool,
    /// another batch; an empty library or everything in the pool, nothing.
    private var capsuleCompletion: BatchProgressCapsule.Completion? {
        if let stateTest {
            switch stateTest {
            case .batchDone: return .nextBatch
            case .everythingSeenWithPool, .everythingSeenEmptyPool: return .startOver
            case .emptyLibrary: return .nothing
            }
        }
        switch topCard {
        case .welcome: return .begin
        // Nothing outside the pool (or no library at all): starting over would only make the same empty batch.
        case .summary: return review.hasMore ? .nextBatch : .nothing
        case .notice(.everythingSeen): return review.hasMore ? .startOver : .nothing
        case .notice(.emptyLibrary): return .nothing
        case .loading, .access, .lesson, .photo: return nil
        }
    }

    /// The words in the middle of the top bar, in their fixed box.
    private var titleView: some View {
        ReviewTitleBar(
            mode: titleMode,
            photoDate: currentAsset?.creationDate,
            isVideo: currentAsset?.mediaType == .video,
            seenCount: review.seenCount,
            selectedCount: pool.isSelecting ? pool.selection.count : 0,
            isCovered: deck.isCovered
        )
    }

    private var titleMode: ReviewTitleBar.Mode {
        if pool.isExpanded { return .pool }
        switch topCard {
        case .photo: return .photo
        case .summary, .notice: return .summary
        case .access, .lesson, .welcome: return .tutorial
        // Still reading: the app's name until there is something to say, unless the photos are known to follow.
        case .loading: return deck.phase == .reviewing ? .summary : .tutorial
        }
    }

    // MARK: Pool

    private var poolActions: PoolActions {
        PoolActions(
            check: openPool,
            restore: pool.restore,
            delete: pool.delete,
            chooseMorePhotos: { presenter.presentLimitedLibraryPicker() }
        )
    }

    /// Opens the pool out of whatever is on top once it opens: a swipe in between moves on.
    private func openPool() {
        pool.open(from: { topCard }, imageSide: poolImageSide * displayScale)
    }

    /// The side every pool photo is requested at: a cell of the grid between the bars, as wide as that room is
    /// now. The summary card asks for the same, so the pictures are cached before the card grows and nothing is
    /// requested anew while it does. Turned sideways the room is wider, and the pictures are fetched again at the
    /// larger size rather than shown enlarged.
    private var poolImageSide: CGFloat {
        // Before the first layout there is no room yet: nothing is requested until there is.
        guard contentFrame.width > 0 else { return 0 }
        return PoolGridMetrics(width: contentFrame.width, gap: PoolGridMetrics.expandedGap).side
    }
}
