import SwiftUI
import LiftCore

/// Every width rule Coach's large-screen layouts use, in one place.
///
/// Layout follows the space a screen actually has, never the device it runs
/// on. An iPad in a narrow Split View window gets the iPhone layout; a large or
/// folding iPhone gets the iPad one as soon as it is wide enough. The numbers
/// are content widths -- the width inside a page's 16 pt padding.
///
/// At iPhone portrait width every rule below resolves to one column, which is
/// the layout Coach has always had.
enum AdaptiveLayout {
    /// A card column narrower than this squeezes a chart or a macro line, so
    /// another column is only added once each can be at least this wide.
    static let cardColumnMinWidth: CGFloat = 320
    /// A day in the seven-column week grid.
    static let dayColumnMinWidth: CGFloat = 128
    /// The space between cards, across and down.
    static let gutter: CGFloat = Theme.cardSpacing
    /// A page's own padding, as `.padding()` applies it.
    static let pagePadding: CGFloat = 16
    /// Beyond this a page stops growing and centres, so a card never becomes a
    /// 1300 pt-wide line of text.
    static let maxContentWidth: CGFloat = 1240
    /// Forms and prose read best at about this width.
    static let readableWidth: CGFloat = 700
    /// The client page's side column (sessions and weeks).
    static let sideColumnWidth: CGFloat = 340
    /// The client page only gives sessions their own column when the charts
    /// beside it can still sit two abreast.
    static let sideColumnMinContentWidth: CGFloat =
        2 * cardColumnMinWidth + gutter + gutter + sideColumnWidth
    /// The roster list beside a client's page.
    static let rosterListWidth: CGFloat = 320
    /// Narrower than this, the Roster stops putting the list beside the page
    /// and pushes the page as on a phone: the page would have under 400 pt.
    static let rosterSplitMinWidth: CGFloat = rosterListWidth + 1 + 400
    /// A window at least this wide starts with the sidebar showing. Below it
    /// -- an iPad in portrait, a mid-size Stage Manager window -- the sidebar
    /// starts hidden so the content keeps the width.
    static let pinnedSidebarMinWindowWidth: CGFloat = 1100
    /// The workout editor's Both / L / R control sits beside a set's numbers
    /// from this width, and on a line of its own under them below it, where a
    /// fourth control would squeeze three number fields to nothing. Wider
    /// than every iPhone in portrait.
    static let sideControlInlineMinWidth: CGFloat = 560

    /// How many columns of at least `minColumnWidth` fit in `width`, clamped
    /// to `1...maxColumns`. Zero or negative width -- a view not yet measured
    /// -- is one column.
    static func columns(for width: CGFloat,
                        minColumnWidth: CGFloat = cardColumnMinWidth,
                        spacing: CGFloat = gutter,
                        maxColumns: Int = 4) -> Int {
        guard width > 0, minColumnWidth > 0, maxColumns > 1 else { return 1 }
        let fit = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        return max(1, min(maxColumns, fit))
    }

    /// Whether a week fits as seven day columns side by side.
    static func showsWeekGrid(width: CGFloat) -> Bool {
        columns(for: width, minColumnWidth: dayColumnMinWidth, maxColumns: 7) == 7
    }

    /// Whether the client page puts sessions in a column of their own.
    static func showsSideColumn(width: CGFloat) -> Bool {
        width >= sideColumnMinContentWidth
    }

    /// Whether the editor's side control fits in the set's own row.
    static func showsSideControlInline(width: CGFloat) -> Bool {
        width >= sideControlInlineMinWidth
    }

    /// The content width a page gets inside a container `containerWidth`
    /// wide, after its padding and the `maxContentWidth` cap.
    static func contentWidth(in containerWidth: CGFloat) -> CGFloat {
        max(0, min(containerWidth, maxContentWidth) - 2 * pagePadding)
    }

}

/// A scrolling page that knows its content width.
///
/// Replaces `ScrollView { VStack { ... }.padding() }`: the content is laid out
/// exactly as before, padded by 16 pt, and additionally capped at
/// `AdaptiveLayout.maxContentWidth` and centred. `content` receives the width
/// inside the padding so it can pick a column count.
struct AdaptiveScrollPage<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    init(@ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    content(AdaptiveLayout.contentWidth(in: proxy.size.width))
                }
                .padding()
                .frame(maxWidth: AdaptiveLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Items in `columns` equal columns, each row as tall as its tallest card.
///
/// One column is a plain `VStack` with the card spacing, so a single-column
/// screen is the same stack it always was. Several are a `Grid`, not a
/// `LazyVGrid`: a `Grid` row stretches a card whose content is marked
/// `fillsGridCell()` to the row's height, so neighbouring cards line up. Coach's
/// lists are tens of items, well within a non-lazy grid.
struct AdaptiveGrid<Item, ID: Hashable, Cell: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let columns: Int
    @ViewBuilder let cell: (Item) -> Cell

    init(_ items: [Item], id: KeyPath<Item, ID>, columns: Int,
         @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.id = id
        self.columns = max(1, columns)
        self.cell = cell
    }

    var body: some View {
        if columns == 1 {
            VStack(alignment: .leading, spacing: AdaptiveLayout.gutter) {
                ForEach(items, id: id) { cell($0) }
            }
        } else {
            Grid(alignment: .topLeading,
                 horizontalSpacing: AdaptiveLayout.gutter,
                 verticalSpacing: AdaptiveLayout.gutter) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row, id: id) { cell($0) }
                        // Pad a short last row so its cards keep the column
                        // width rather than stretching across the gap.
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes(.vertical)
                        }
                    }
                }
            }
        }
    }

    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
    }
}

extension AdaptiveGrid where Item: Identifiable, ID == Item.ID {
    init(_ items: [Item], columns: Int, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.init(items, id: \.id, columns: columns, cell: cell)
    }
}

extension View {
    /// Lets a card's content grow to its grid row's height. Inert in a
    /// vertical stack, where nothing proposes a height.
    func fillsGridCell() -> some View {
        frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// A screen's name as its navigation title at regular width, where the
    /// sidebar replaces the top tab row that names it on iPhone. At compact
    /// width the title stays empty, as it always was: the tab row already says
    /// it, and saying it twice stacked the word on itself.
    func regularWidthTitle(_ title: String) -> some View {
        modifier(RegularWidthTitle(title: title))
    }
}

private struct RegularWidthTitle: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String

    func body(content: Content) -> some View {
        content.navigationTitle(sizeClass == .regular ? title : "")
    }
}

extension View {
    /// Moves a custom top-leading header clear of an iPadOS window's own
    /// close / minimise / zoom controls.
    ///
    /// A navigation bar makes this room by itself; Coach's wordmark header is
    /// not a navigation bar, so in a windowed iPad app the controls sat on top
    /// of "LIFT". The inset is read from UIKit's corner-adapted safe area
    /// (iOS 26), which is zero wherever no control is in the corner -- a phone,
    /// a full-screen iPad app, and every iOS before 26.
    func clearsWindowControls() -> some View {
        modifier(ClearsWindowControls())
    }
}

private struct ClearsWindowControls: ViewModifier {
    @State private var leading: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            .background(CornerInsetReader(leading: $leading))
    }
}

private struct CornerInsetReader: UIViewRepresentable {
    @Binding var leading: CGFloat

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = { value in
            if abs(value - leading) > 0.5 { leading = value }
        }
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard #available(iOS 26.0, *) else { return }
            let adapted = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal)).layoutFrame
            // Only what the corner adds beyond the plain safe area, so a
            // landscape phone's notch inset is not counted twice.
            let extra = max(0, adapted.minX - safeAreaInsets.left)
            DispatchQueue.main.async { [weak self] in self?.onChange?(extra) }
        }
    }
}
