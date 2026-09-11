import SwiftUI

/// Design tokens extracted from the Android build of LIFT.
/// Colours sampled directly from app screenshots — do not eyeball replacements.
///
/// Ported verbatim from `lift-ios`'s `Sources/App/Theme.swift` (same hex
/// values, same token names) so Coach visually matches LIFT on every
/// platform. `LiftCard` and `.liftScreen()` are ported too, since Coach's
/// screens are also card-and-list-based; `LiftChip`, `MacroProgressRow`, and
/// `StatRow` are LIFT-screen-specific and are not needed here.
enum Theme {

    // MARK: Colour

    /// Warm near-black page background.
    static let background = Color(hex: 0x1C1B19)
    /// Slightly cool grey used for every card surface.
    static let surface = Color(hex: 0x36353B)
    /// Rust/burnt orange. Headings, active tab, filled chips, progress, destructive.
    static let accent = Color(hex: 0xC1442C)
    /// Dimmed accent for pressed and disabled states.
    static let accentMuted = Color(hex: 0x883223)

    static let textPrimary = Color(hex: 0xEFEDE9)
    static let textSecondary = Color(hex: 0x9B9995)
    static let hairline = Color(hex: 0x4A484E)

    // MARK: Metrics

    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 9
    static let cardPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 12

    // MARK: Type

    /// Orange card heading — "Training", "Fuel so far today".
    static let cardTitle = Font.system(size: 17, weight: .bold)
    /// Large figure — "635 kcal over".
    static let figure = Font.system(size: 26, weight: .bold)
    static let body = Font.system(size: 16)
    static let detail = Font.system(size: 14)
    static let sectionLabel = Font.system(size: 15, weight: .bold)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Components

/// The card that carries almost every surface in the app.
struct LiftCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.accent)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

extension View {
    /// Applies the page background and default text colour.
    ///
    /// `.scrollBounceBehavior(.always)` is deliberate: without it a ScrollView
    /// whose content fits the screen is completely inert, which is
    /// indistinguishable from broken scrolling.
    func liftScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollBounceBehavior(.always)
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
    }
}
