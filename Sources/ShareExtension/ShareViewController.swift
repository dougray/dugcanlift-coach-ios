import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LiftCore

/// The share sheet's entry point: finds a LIFT log link in what was shared,
/// asks the coach to confirm it, and queues its fragment for the app
/// (`PendingShareLinks`). The app imports it the next time it comes to the
/// foreground, through Paste a Link's own code path.
///
/// Nothing here touches SwiftData. The link is decoded only to show who it is
/// from and to refuse a bad one before the coach leaves the share sheet.
final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        let host = UIHostingController(rootView: ShareConfirmView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor in
            model.resolve(candidates: await Self.candidateTexts(in: items))
        }
    }

    /// Every string the share could be carrying a link in: shared URLs,
    /// shared text, and the item's own text (Messages and Mail put the
    /// message body there). Order is only a preference; the first that
    /// decodes wins.
    private static func candidateTexts(in items: [NSExtensionItem]) async -> [String] {
        var texts: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(url.absoluteString)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let string = loaded as? String { texts.append(string) }
                    else if let data = loaded as? Data, let string = String(data: data, encoding: .utf8) { texts.append(string) }
                }
            }
            if let body = item.attributedContentText?.string, !body.isEmpty {
                texts.append(body)
            }
        }
        return texts
    }
}

@MainActor
final class ShareModel: ObservableObject {

    enum State {
        case reading
        case ready(summary: String, fragment: String)
        case notALink
        /// The web Coach page with no log in its address. The web app strips
        /// the fragment as soon as it loads a link, so this is what Safari
        /// shares from a link it has already opened.
        case openedInSafari
        /// The build is missing the App Group entitlement, so nothing written
        /// here would reach the app. Said plainly rather than failing quietly.
        case noSharedStorage
    }

    @Published var state: State = .reading
    var finish: () -> Void = {}

    func resolve(candidates: [String]) {
        for text in candidates {
            guard let fragment = ShareLinkExtractor.fragment(in: text),
                  let payload = try? ShareLinkCodec.decode(fragment: fragment)
            else { continue }
            state = .ready(summary: ShareLinkExtractor.summary(of: payload), fragment: fragment)
            return
        }
        state = candidates.contains(where: ShareLinkExtractor.isCoachPageWithoutLog) ? .openedInSafari : .notALink
    }

    func add(_ fragment: String) {
        guard let inbox = PendingShareLinks.shared else {
            state = .noSharedStorage
            return
        }
        inbox.add(fragment)
        finish()
    }
}

struct ShareConfirmView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                content
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.finish() }
                        .foregroundStyle(Theme.textSecondary)
                }
                if case .ready(_, let fragment) = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { model.add(fragment) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .liftAppearance()
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .reading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        case .ready(let summary, _):
            LiftCard(title: "Add to Coach") {
                Text("Add \(summary)")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Coach imports it the next time you open the app.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .notALink:
            LiftCard {
                Text("That doesn't look like a LIFT link")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                // Verbatim, or SwiftUI turns the address into a tappable link.
                Text(verbatim: "Share the log link a client sent from LIFT. It starts with www.dugcanlift.com/coach/#.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .openedInSafari:
            LiftCard {
                Text("The log isn't in this address")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("This page has already opened the log, which removes it from the address. Share the link from the message or email it arrived in instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .noSharedStorage:
            LiftCard {
                Text("This build of Coach can't pass links from the share sheet. Copy the link and use Paste a Link in Coach instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}
