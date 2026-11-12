import SwiftUI
import Combine
import LiftCore
import LiftMap
import LiftMapCore

/// "Download streets for this route", under a client's route card, shown only
/// while the route is drawn as the plain line (`RouteMapDecision.line`) and
/// there is a route to draw streets for. A plain button, not a banner: nothing
/// asks for the streets until the coach taps it, and the sheet says what the
/// download is, how large, and what the server learns before anything is
/// requested.
///
/// **The button comes and goes; the sheet does not.** A download holds the
/// store's write gate, which hides the button (`shouldOffer`), so a sheet
/// attached to the button would be torn down mid-download, taking its progress
/// and its "Couldn't finish" with it. The sheet is `RouteStreetsSheet`,
/// presented from a view that is always on screen (the route card), through the
/// binding this button sets.
struct RouteStreetsOffer: View {
    static let title = "Download streets for this route"
    static let note = "This asks for the area around your client's route."

    let points: [OutdoorShareCoordinate]
    @Binding var presenting: Bool
    var store: StreetStore? = StreetStore.shared

    @State private var revision = 0

    var body: some View {
        // `revision` is read so a finished download, an area deleted in
        // Connect, or a download beginning decides this again.
        let _ = revision
        Group {
            if let store, Self.shouldOffer(points: points, store: store) {
                Button(Self.title) { presenting = true }
                    .font(.subheadline)
                    .tint(Theme.accentText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: StreetStore.didChange, object: store)
            .receive(on: DispatchQueue.main)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: StreetStore.writingDidChange, object: store)
            .receive(on: DispatchQueue.main)) { _ in revision += 1 }
    }

    /// The line is showing and a route could be covered. A route of fewer than
    /// two points is the line but has no area to download: `MapBounds.around`
    /// still answers for one point, with a box of nothing. While the store is
    /// being written the map steps back to the line too, but a download
    /// already under way is no moment to start another.
    static func shouldOffer(points: [OutdoorShareCoordinate], store: StreetStore) -> Bool {
        guard points.count >= 2, !store.isWriting else { return false }
        return RouteMapDecision.decide(points: points) { (try? store.covers($0)) ?? false } == .line
    }

    static func areaName(_ clientName: String) -> String { clientName + "'s route" }
}

/// The download sheet for a client's route. Dismissed only by its own Cancel
/// or by finishing (`onDone`), never by the offer button going away.
struct RouteStreetsSheet: View {
    let points: [OutdoorShareCoordinate]
    let clientName: String
    var store: StreetStore? = StreetStore.shared
    let onDone: () -> Void

    var body: some View {
        if let store, let bounds = MapBounds.around(points) {
            StreetsSheet(plan: .forRoute(bounds), name: RouteStreetsOffer.areaName(clientName),
                         store: store, note: RouteStreetsOffer.note) { _ in onDone() }
                .liftAppearance()
        }
    }
}
