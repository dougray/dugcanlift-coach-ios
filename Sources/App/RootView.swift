import SwiftUI
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Paste a Link, when it is asked for from the keyboard rather than from
    /// the Roster's own button.
    @State private var pastingFromCommand = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        shell
        .background(Theme.background)
        .tint(Theme.accent)
        .liftAppearance()
        .focusedSceneValue(\.coachNavigation, CoachNavigation(
            select: { item in withAnimation(.easeOut(duration: 0.18)) { tab = item } },
            pasteLink: {
                tab = .roster
                pastingFromCommand = true
            }))
        .sheet(isPresented: $pastingFromCommand) { PasteLinkView() }
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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tab == item ? Theme.onAccent : Theme.textPrimary)
                        .tag(item)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: Theme.chipRadius)
                                .fill(tab == item ? Theme.accent : .clear)
                                .padding(.horizontal, 8)
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

    /// "LIFT Coach" — accent wordmark, the second word muted and unbolded, as
    /// `h1 span` renders it on the web.
    private var header: some View {
        HStack(spacing: 6) {
            Text("LIFT")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.accent)
            Text("Coach")
                .font(.system(size: 28, weight: .regular))
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
