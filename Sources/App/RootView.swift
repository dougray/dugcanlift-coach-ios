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
struct RootView: View {

    private enum Tab: String, CaseIterable, Identifiable {
        case roster = "Roster"
        case cook = "Cook"
        case train = "Train"
        case connect = "Connect"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .roster
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// What the last link that arrived from outside the app did -- a
    /// `dugcanliftcoach://` URL or the share extension's queue. Paste a Link
    /// reports in its own sheet instead.
    @State private var intakeReport: IntakeReport?

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
        .onOpenURL { url in
            report(importing: [url.absoluteString])
        }
        // `.active` covers both a cold launch and returning from the share
        // sheet, which is when the extension's queue has something in it.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, let inbox = PendingShareLinks.shared else { return }
            let queued = inbox.takeAll()
            if !queued.isEmpty { report(importing: queued) }
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

    private struct IntakeReport {
        let title: String
        let message: String
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
        if failed == 0 {
            intakeReport = IntakeReport(title: "Log imported", message: added.joined(separator: "\n"))
        } else if added.isEmpty {
            intakeReport = IntakeReport(title: "Couldn't import", message: ShareLinkImporter.invalidLinkMessage)
        } else {
            intakeReport = IntakeReport(
                title: "Some links didn't import",
                message: (added + ["\(failed) link\(failed == 1 ? "" : "s") could not be read."]).joined(separator: "\n"))
        }
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
