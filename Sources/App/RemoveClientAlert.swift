import SwiftUI
import SwiftData
import LiftCore

/// The one confirmation behind every way to remove a client.
///
/// The client page's "Remove this client" and the roster row's long-press
/// menu both attach this, so both say and do exactly the same thing -- the
/// invariant Coach Android states outright, where the same dialog is hosted by
/// both screens. A row that deleted on its own, with a lighter question or
/// none, would make the roster the quiet way to lose a client's logged months.
///
/// The counts are gathered before the alert appears (the caller sets
/// `pending` to a `RemovalImpact`), so the sentence never changes under a
/// thumb.
struct RemoveClientAlert: ViewModifier {
    @Binding var pending: RemovalImpact?
    /// Called with the client's id once they are gone, for the caller to leave
    /// the page or clear its selection. Never called for a removal that did
    /// not happen -- that stays put and says so.
    let onRemoved: (String) -> Void

    @Environment(\.modelContext) private var context
    /// Cook's and Train's Plan client, shared across the scene by this key. A
    /// removed client left selected here is a picker showing nothing and a
    /// week that cannot be explained.
    @SceneStorage("planClientID") private var planClientID: String = ""
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(ClientRemoval.confirmationTitle(pending),
                   isPresented: Binding(get: { pending != nil },
                                        set: { if !$0 { pending = nil } }),
                   presenting: pending) { impact in
                Button("Remove", role: .destructive) { remove(impact) }
                Button("Keep", role: .cancel) { pending = nil }
            } message: { impact in
                Text(ClientRemoval.confirmationText(impact))
            }
            .alert("Couldn't Remove",
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in
                Button("OK", role: .cancel) { failure = nil }
            } message: { message in
                Text(message)
            }
    }

    private func remove(_ impact: RemovalImpact) {
        let outcome = ClientRemoval.remove(clientID: impact.clientID, in: context)
        pending = nil
        guard outcome.removed else {
            // On its own turn: SwiftUI drops a second alert raised in the same
            // pass that dismisses the first, and a removal that failed is
            // exactly when the coach must be told.
            let message = outcome.message
            DispatchQueue.main.async { failure = message }
            return
        }
        if planClientID == impact.clientID { planClientID = "" }
        onRemoved(impact.clientID)
    }
}

extension View {
    /// Confirms removing the client in `pending`, names what goes, and removes
    /// them on a yes. See `RemoveClientAlert`.
    func removeClientAlert(_ pending: Binding<RemovalImpact?>,
                           onRemoved: @escaping (String) -> Void) -> some View {
        modifier(RemoveClientAlert(pending: pending, onRemoved: onRemoved))
    }
}
