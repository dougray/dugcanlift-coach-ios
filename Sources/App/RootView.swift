import SwiftUI
import SwiftData
import LiftCore

/// The browser build's shell, rather than a stock iOS one.
///
/// This app used a bottom `TabView` with SF Symbols where the browser build has
/// a wordmark and a top tab row. That is a structural difference, not a colour
/// one, and it is what made the two look like different products rather than
/// the same product on two screens.
///
/// The tab set is unchanged. The browser build also has a `Client` tab, but it
/// is a destination for a roster row rather than somewhere you navigate
/// directly -- it sits there `disabled` until a client is picked. Here that is
/// a push from `RosterView`, which is the same idea in the idiom of the
/// platform, so no fifth tab.
///
/// At regular width -- an iPad, a large iPhone in landscape, a wide Stage
/// Manager window -- the tab row becomes a sidebar and the Roster becomes a
/// list beside the selected client's page. The size class decides, never the
/// device: an iPad in a narrow Split View window is compact and gets exactly
/// the iPhone shell.
struct RootView: View {
    /// The wordmark's 28pt, scaled with Dynamic Type so it stays above the
    /// text it heads at large sizes.
    @ScaledMetric(relativeTo: .title) private var wordmarkSize: CGFloat = 28


    enum Tab: String, CaseIterable, Identifiable {
        case roster = "Roster"
        case cook = "Cook"
        case train = "Train"
        case connect = "Connect"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .roster: "person.2"
            case .cook: "fork.knife"
            case .train: "dumbbell"
            case .connect: "arrow.left.arrow.right"
            }
        }
    }

    @State private var tab: Tab = .roster
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// What the last link that arrived from outside the app did -- a
    /// `dugcanliftcoach://` URL or the share extension's queue. Paste a Link
    /// reports in its own sheet instead.
    @State private var intakeReport: IntakeReport?
    /// Recipes Safari handed over, the rules for when each may open, and the
    /// App Group files kept in step with them (`RecipeIntake`).
    @State private var recipes = RecipeIntake<IntakeReport>(inbox: PendingRecipeImports.shared)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Paste a Link, when it is asked for from the keyboard rather than from
    /// the Roster's own button.
    @State private var pastingFromCommand = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        shell
        .background(Theme.background)
        .tint(Theme.accentText)
        .liftAppearance()
        .focusedSceneValue(\.coachNavigation, CoachNavigation(
            select: { item in withAnimation(.easeOut(duration: 0.18)) { tab = item } },
            pasteLink: {
                // A second sheet over a recipe under review would be dropped,
                // and could strand the review: ⇧⌘V waits until it closes.
                guard recipes.reviewing == nil else { return }
                tab = .roster
                pastingFromCommand = true
            }))
        .sheet(isPresented: $pastingFromCommand) { PasteLinkView() }
        // The host decides before anything reads the fragment: `recipe` is the
        // "Send to Coach" bookmarklet's, and everything else is a log link, as
        // it always was (`CoachURLRoute`).
        .onOpenURL { url in
            switch CoachURLRoute(url) {
            case .log(let text):
                report(importing: [text])
            case .recipe(let item):
                recipes.received(item)
                // When not yet active, the activation that follows opens it, after
                // `activated()` has read the inbox; opening it here as well
                // would have that activation take it for a dropped sheet.
                if scenePhase == .active { presentNextRecipe() }
            case .unreadableRecipe:
                show(.recipeLinkUnreadable)
            case .noRecipe:
                show(.recipeLinkHoldsNoRecipe)
            }
        }
        // `.active` covers both a cold launch and returning from the share
        // sheet, which is when the extension's queues have something in them.
        // Links first, then recipes, the order the extension decides in.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            // Reads the recipe files without emptying them: one goes only
            // when its review finishes, so iOS ending Coach mid-review loses
            // nothing.
            recipes.activated()
            if let inbox = PendingShareLinks.shared {
                let queued = inbox.takeAll()
                if !queued.isEmpty { report(importing: queued) }
            }
            presentNextRecipe()
        }
        // One presentation at a time on this view: a recipe waits for the link
        // report's alert and the paste sheet (see `RecipeReviewQueue`).
        .onChange(of: intakeReport == nil) { _, clear in
            if clear { advance() }
        }
        .onChange(of: pastingFromCommand) { _, showing in
            if !showing { presentNextRecipe() }
        }
        .sheet(item: Binding(get: { recipes.reviewing },
                             set: { if $0 == nil { recipes.closing() } }),
               onDismiss: afterRecipeReview) { queued in
            RecipeLinkImportView(item: queued.item)
                .onAppear { recipes.appeared(queued.id) }
                // Cancel and Save only: a close is what deletes the recipe
                // from the App Group, so a swipe must not be one.
                .interactiveDismissDisabled()
                .liftAppearance()
        }
        .alert(intakeReport?.title ?? "", isPresented: Binding(
            get: { intakeReport != nil },
            set: { if !$0 { intakeReport = nil } }
        ), presenting: intakeReport) { _ in
            Button("OK") { intakeReport = nil }
        } message: { report in
            Text(report.message)
        }
    }

    @ViewBuilder
    private var shell: some View {
        if sizeClass == .regular {
            regularShell
        } else {
            compactShell
        }
    }

    // MARK: - Compact: wordmark and top tab row

    private var compactShell: some View {
        VStack(spacing: 0) {
            header
            LiftTabBar {
                ForEach(Tab.allCases) { item in
                    LiftTabButton(label: item.rawValue, isSelected: tab == item) {
                        withAnimation(.easeOut(duration: 0.18)) { tab = item }
                    }
                }
            }

            // Each case keeps its own NavigationStack so a push inside one tab
            // is not unwound by switching to another and back -- the behaviour
            // the previous TabView had for free.
            switch tab {
            case .roster:  NavigationStack { RosterView() }
            case .cook:    CookView()
            case .train:   TrainView()
            case .connect: NavigationStack { ConnectView() }
            }
        }
    }

    // MARK: - Regular: sidebar

    private var regularShell: some View {
        GeometryReader { proxy in
            let roomy = proxy.size.width >= AdaptiveLayout.pinnedSidebarMinWindowWidth
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            } detail: {
                switch tab {
                case .roster:  RosterSplitView()
                case .cook:    CookView()
                case .train:   TrainView()
                case .connect: NavigationStack { ConnectView() }
                }
            }
            .navigationSplitViewStyle(.automatic)
            // The sidebar starts beside the content only when the window is
            // wide enough to keep it there -- an iPad in landscape. Narrower,
            // it starts hidden behind its toggle, because pinned it left a
            // client's page too narrow for the charts to sit two abreast. Set
            // on appearing as well as on crossing the line: a window that grows
            // out of compact width builds this view fresh.
            // Deferred past the split view's first layout: a visibility set
            // during it -- in onAppear, or at the start of a task -- was
            // overridden by the split view's own default and the sidebar
            // showed anyway.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                columnVisibility = roomy ? .all : .detailOnly
            }
            .onChange(of: roomy) { _, now in columnVisibility = now ? .all : .detailOnly }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<Tab?>(get: { tab }, set: { if let new = $0 { tab = new } })) {
            Section {
                ForEach(Tab.allCases) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .font(.headline)
                        .foregroundStyle(tab == item ? Theme.onAccent : Theme.textPrimary)
                        .tag(item)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .fill(tab == item ? Theme.accent : .clear)
                                .padding(.horizontal, 8)
                                .background(FocusHaloRemover())
                        )
                }
            } header: {
                header
                    .padding(.horizontal, -16)
                    .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Opens the next waiting recipe, unless something is already on screen.
    private func presentNextRecipe() {
        _ = recipes.next(canPresent: intakeReport == nil && !pastingFromCommand)
    }

    /// A review's sheet has gone: the next may open (`advance()`).
    private func afterRecipeReview() {
        recipes.closed()
        advance()
    }

    /// Whatever is on screen has gone. A link report that arrived during a
    /// review is shown first, one alert at a time, and the next recipe opens
    /// after the last alert's OK; with none held, it opens at once.
    private func advance() {
        if let held = recipes.takeHeldReport() { intakeReport = held; return }
        presentNextRecipe()
    }

    private struct IntakeReport {
        let title: String
        let message: String

        /// A log link Coach could not read.
        static let couldNotImport = IntakeReport(title: "Couldn't import",
                                                 message: ShareLinkImporter.invalidLinkMessage)
        /// A "Send to Coach" link that did not decode, and one with no recipe
        /// in it -- the bookmarklet's shared wording, the same in every build.
        static let recipeLinkUnreadable = IntakeReport(title: "Couldn't import",
                                                       message: RecipeLink.unreadableMessage)
        static let recipeLinkHoldsNoRecipe = IntakeReport(title: "Couldn't import",
                                                          message: RecipeLink.noRecipeMessage)
    }

    /// Imports each link through `ShareLinkImporter.importLink` -- Paste a
    /// Link's own path -- and says what happened, on the Roster, where an
    /// imported client appears.
    private func report(importing texts: [String]) {
        var added: [String] = []
        var failed = 0
        for text in texts {
            do {
                added.append(ShareLinkExtractor.summary(of: try ShareLinkImporter.importLink(text, into: context)))
            } catch {
                failed += 1
            }
        }
        tab = .roster
        let made: IntakeReport
        if failed == 0 {
            made = IntakeReport(title: "Log imported", message: added.joined(separator: "\n"))
        } else if added.isEmpty {
            made = .couldNotImport
        } else {
            made = IntakeReport(
                title: "Some links didn't import",
                message: (added + ["\(failed) link\(failed == 1 ? "" : "s") could not be read."]).joined(separator: "\n"))
        }
        show(made)
    }

    /// An alert beside an open recipe sheet would be dropped: hold it.
    private func show(_ made: IntakeReport) {
        if let now = recipes.report(made) { intakeReport = now }
    }

    /// "LIFT Coach" — accent wordmark, the second word muted and unbolded, as
    /// `h1 span` renders it on the web.
    private var header: some View {
        HStack(spacing: 6) {
            Text("LIFT")
                .font(.system(size: wordmarkSize, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.accent)
            Text("Coach")
                .font(.system(size: wordmarkSize, weight: .regular))
                .tracking(-0.5)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .clearsWindowControls()
    }
}

/// Removes UIKit's focus halo from the sidebar cell it is placed in.
///
/// On iPadOS with a keyboard attached, the focus system puts the sidebar's
/// selected cell in focus -- at launch, and again whenever a menu or sheet is
/// dismissed and focus is restored. A `UICollectionViewCell` shows focus
/// through its background configuration when it has the system one, and falls
/// back to a halo (tinted with the accent, so red) when it does not. The
/// sidebar's `listRowBackground` replaces that configuration with the accent
/// pill, so every restore left a red outline stuck around the selected row
/// until something else was tapped. SwiftUI's `.focusEffectDisabled()` does not
/// reach that halo; the cell's own `focusEffect` does, once set explicitly.
///
/// Only the drawing goes. The cell stays focusable, arrow keys still move the
/// selection (the pill follows it, which is the visible focus), and
/// `CoachCommands`' ⌘1-4 do not use focus at all.
private struct FocusHaloRemover: UIViewRepresentable {
    func makeUIView(context: Context) -> CellProbe { CellProbe() }
    func updateUIView(_ view: CellProbe, context: Context) {}

    final class CellProbe: UIView {
        private weak var handled: UICollectionViewCell?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            removeHalo()
        }

        // SwiftUI can move a row's background into a different (reused) cell
        // without a new window, so check again on layout.
        override func layoutSubviews() {
            super.layoutSubviews()
            removeHalo()
        }

        private func removeHalo() {
            var view = superview
            while let current = view {
                if let cell = current as? UICollectionViewCell {
                    guard cell !== handled else { return }
                    // A nil the cell was never given means "use the default
                    // halo"; assigned, it means no effect.
                    cell.focusEffect = nil
                    handled = cell
                    return
                }
                view = current.superview
            }
        }
    }
}
