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
struct RouteStreetsOffer: View {
    static let title = "Download streets for this route"
    static let note = "This asks for the area around your client's route."

    let points: [OutdoorShareCoordinate]
    let clientName: String
    var store: StreetStore? = StreetStore.shared

    @State private var revision = 0
    @State private var presenting = false

    var body: some View {
        // `revision` is read so a finished download, or an area deleted in
        // Connect, decides this again.
        let _ = revision
        Group {
            if let store, let bounds = MapBounds.around(points), Self.shouldOffer(points: points, store: store) {
                Button(Self.title) { presenting = true }
                    .font(.subheadline)
                    .tint(Theme.accentText)
                    .sheet(isPresented: $presenting) {
                        StreetsSheet(plan: .forRoute(bounds), name: Self.areaName(clientName),
                                     store: store, note: Self.note) { _ in
                            presenting = false
                            revision += 1
                        }
                        .liftAppearance()
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: StreetStore.didChange, object: store)
            .receive(on: DispatchQueue.main)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: StreetStore.writingDidChange, object: store)
            .receive(on: DispatchQueue.main)) { _ in revision += 1 }
    }

    /// The line is showing and a route could be covered. While the store is
    /// being written the map steps back to the line too, but a download
    /// already under way is no moment to start another.
    static func shouldOffer(points: [OutdoorShareCoordinate], store: StreetStore) -> Bool {
        guard !store.isWriting else { return false }
        return RouteMapDecision.decide(points: points) { (try? store.covers($0)) ?? false } == .line
    }

    static func areaName(_ clientName: String) -> String { clientName + "'s route" }
}
