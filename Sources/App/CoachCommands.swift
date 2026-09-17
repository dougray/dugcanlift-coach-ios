import SwiftUI

/// Keyboard shortcuts, for an iPad with a keyboard attached (or an iPhone with
/// one). Hold ⌘ on an iPad to see them listed.
///
/// Scene commands rather than hidden buttons: they reach the ⌘ overlay and the
/// iPadOS menu bar with their names, and they cost nothing where no keyboard is
/// attached. The screens publish what the commands act on as focused scene
/// values, so a command that has nothing to act on -- New Recipe while the
/// Roster is showing -- is simply disabled.
struct CoachCommands: Commands {
    @FocusedValue(\.coachNavigation) private var navigation
    @FocusedValue(\.coachNewItem) private var newItem

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newItem?.title ?? "New") { newItem?.action() }
                .keyboardShortcut("n")
                .disabled(newItem == nil)
            // ⇧⌘V, not ⌘V: plain ⌘V belongs to whichever text field has focus,
            // and taking it over would break pasting everywhere else in Coach.
            Button("Paste a Link") { navigation?.pasteLink() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(navigation == nil)
        }
        CommandMenu("Go") {
            ForEach(Array(RootView.Tab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) { navigation?.select(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(navigation == nil)
            }
        }
    }
}

/// What the root view lets a command do.
struct CoachNavigation {
    let select: (RootView.Tab) -> Void
    let pasteLink: () -> Void
}

/// The screen's own "new" action -- a recipe in Cook, a workout in Train.
struct CoachNewItem {
    let title: String
    let action: () -> Void
}

private struct CoachNavigationKey: FocusedValueKey { typealias Value = CoachNavigation }
private struct CoachNewItemKey: FocusedValueKey { typealias Value = CoachNewItem }

extension FocusedValues {
    var coachNavigation: CoachNavigation? {
        get { self[CoachNavigationKey.self] }
        set { self[CoachNavigationKey.self] = newValue }
    }
    var coachNewItem: CoachNewItem? {
        get { self[CoachNewItemKey.self] }
        set { self[CoachNewItemKey.self] = newValue }
    }
}
