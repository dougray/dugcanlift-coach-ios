import SwiftUI
import LiftCore

/// `LiftCore.liftScreen()` plus text buttons that are actually the accent colour.
///
/// `liftScreen()` sets `.foregroundStyle(Theme.textPrimary)` for the whole
/// screen, and an environment foreground style wins over `.tint` for a
/// button's label. So every text button on these screens — Edit, Delete, New
/// recipe, Book a workout, Clear ticks — drew in body text colour and read as
/// plain text, while `.tint(Theme.accent)` sat there doing nothing. The style
/// below colours the label with the tint itself, which the environment cannot
/// override. A button that chooses its own style or colours its own label is
/// unaffected: the closer modifier still wins.
struct AccentTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            // The label alone was the hit area: about 16pt tall for a caption
            // "Remove", 13pt square for an xmark. HIG's 44pt minimum, without
            // changing how the label looks.
            .minimumHitTarget()
    }
}

extension View {
    /// At least 44x44pt to tap, drawn at the size it already is. For Menus and
    /// other controls `AccentTextButtonStyle` does not reach.
    func minimumHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Use in place of `liftScreen()` on Coach's scrolling screens.
    func coachScreen() -> some View {
        liftScreen()
            .buttonStyle(AccentTextButtonStyle())
    }
}
