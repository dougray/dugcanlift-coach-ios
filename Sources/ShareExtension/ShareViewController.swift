import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LiftCore

/// The share sheet's entry point, for one of two things (`RecipeShareDecision`
/// decides which, and a link always wins):
///
/// - **A LIFT log link** in what was shared, or the web Coach page's own
///   address. The coach confirms it and its fragment is queued for the app
///   (`PendingShareLinks`), which imports it the next time it comes to the
///   foreground, through Paste a Link's own code path.
/// - **A recipe from the page Safari shared.** `RecipePage.js` hands over the
///   page's JSON-LD; the coach confirms the recipe and its raw block is queued
///   (`PendingRecipeImports`) for the app to open for review.
///
/// Nothing here touches SwiftData or the network. A link is decoded, and a
/// recipe read, only to show what it is and to refuse a bad one before the
/// coach leaves the share sheet.
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
            let shared = await Self.sharedContent(in: items)
            model.resolve(candidates: shared.texts, page: shared.page)
        }
    }

    /// Every string the share could be carrying a link in -- shared URLs,
    /// shared text, the item's own text (Messages and Mail put the message
    /// body there) -- and, when the share came from Safari, what RecipePage.js
    /// returned. Order of the strings is only a preference; the first that
    /// decodes wins.
    private static func sharedContent(in items: [NSExtensionItem]) async -> (texts: [String], page: SharedRecipePage?) {
        var texts: [String] = []
        var page: SharedRecipePage?
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
                   let results = (loaded as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] {
                    page = page ?? SharedRecipePage(preprocessingResults: results)
                }
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
        return (texts, page)
    }
}

@MainActor
final class ShareModel: ObservableObject {

    enum State {
        case reading
        case ready(summary: String, fragment: String)
        /// A schema.org recipe on the page Safari shared.
        case recipe(name: String, servings: Double?, item: PendingRecipeImports.Item)
        /// A page from Safari with no link and no recipe card.
        case noRecipe
        case notALink
        /// The web Coach page with no log in its address. The web app strips
        /// the fragment as soon as it loads a link, so this is what Safari
        /// shares from a link it has already opened.
        case openedInSafari
        /// The build is missing the App Group entitlement, so nothing written
        /// here would reach the app. Said plainly rather than failing quietly.
        case noSharedStorage
        /// The same missing App Group, met while adding a recipe: the way
        /// round is Paste the text, not Paste a Link.
        case noSharedStorageForRecipe
    }

    @Published var state: State = .reading
    var finish: () -> Void = {}

    /// A LIFT log link or the web Coach page, which the link flow answers.
    static func isLink(_ text: String) -> Bool { ShareLinkExtractor.isLink(text) }

    func resolve(candidates: [String], page: SharedRecipePage?) {
        switch RecipeShareDecision.decide(candidates: candidates, page: page, isLink: Self.isLink) {
        case let .useLinkFlow(linkCandidates):
            // Includes the page's own address when Safari passed only the page.
            resolveLink(candidates: linkCandidates)
        case let .recipe(name, servings, item):
            state = .recipe(name: name, servings: servings, item: item)
        case .noRecipe:
            state = .noRecipe
        }
    }

    func addRecipe(_ item: PendingRecipeImports.Item) {
        guard let inbox = PendingRecipeImports.shared, (try? inbox.add(item)) != nil else {
            state = .noSharedStorageForRecipe
            return
        }
        finish()
    }

    func resolveLink(candidates: [String]) {
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
                if case .recipe(_, _, let item) = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { model.addRecipe(item) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
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
        case let .recipe(name, servings, _):
            LiftCard(title: "Add to Coach") {
                Text("Add \(name)")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let servings {
                    Text("Serves \(CookFormat.trimmed(servings))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Coach shows it for review the next time you open it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .noRecipe:
            LiftCard {
                Text("There's no recipe card on this page")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Copy the recipe's text and use Paste the text in Coach instead.")
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
        case .noSharedStorageForRecipe:
            LiftCard {
                Text("This build of Coach can't pass recipes from the share sheet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Copy the recipe's text and use Paste the text in Coach instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
