import SwiftUI
import UIKit
import LiftCore

/// What "Send recipes from your browser" in Cook's Import menu opens: the
/// "Send to Coach" bookmarklet (`dugcanlift-kit`'s `bookmarklet/`), a Copy
/// button, and how to save it in Chrome on iPhone. Safari's share sheet
/// already does the same thing, so this is for every other browser.
///
/// The bookmarklet reads the recipe the browser already has on screen and
/// opens `dugcanliftcoach://recipe#r1…`; Coach decodes it (`RecipeLink`) and
/// opens the same review as a Safari share. Neither requests the page.
struct BrowserBookmarkletView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Byte for byte from the bundled `bookmarklets.json`.
    private let bookmarklet = Bookmarklets.coachApp()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    Text("Save this as a bookmark once. On any recipe page, tap the bookmark and the recipe opens here for you to check. Coach never visits the page.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)

                    if let bookmarklet {
                        LiftCard(title: "Send to Coach") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(bookmarklet)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(4)
                                    .truncationMode(.tail)
                                    .accessibilityHidden(true)
                                Button {
                                    UIPasteboard.general.string = bookmarklet
                                    copied = true
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(Theme.body.weight(.semibold))
                                }
                                .buttonStyle(AccentTextButtonStyle())
                                .tint(Theme.accentText)
                            }
                        }
                    }

                    LiftCard {
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Tap Copy.")
                            step(2, "Bookmark any page.")
                            step(3, "Edit the bookmark. Name it Send to Coach, and paste over its address.")
                            step(4, "On a recipe page, type Send to Coach in the address bar and tap the bookmark.")
                        }
                    }

                    Text("In Safari, Share → Coach does the same.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Send recipes from your browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .liftAppearance()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(Theme.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accentText)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
