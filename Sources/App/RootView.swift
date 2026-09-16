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
struct RootView: View {

    private enum Tab: String, CaseIterable, Identifiable {
        case roster = "Roster"
        case cook = "Cook"
        case train = "Train"
        case connect = "Connect"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .roster

    var body: some View {
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
        .background(Theme.background)
        .tint(Theme.accent)
        .liftAppearance()
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
    }
}
