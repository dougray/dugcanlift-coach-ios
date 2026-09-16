import Foundation
import SwiftData
import LiftCore

/// One ticked line on one client's shopping list.
///
/// Coach's own replacement for `LiftCore.ShoppingListCheck`, which is keyed by
/// item name alone because on LIFT the list belongs to the only person on the
/// device. In Coach that made ticking "lean beef mince" for one client tick it
/// for every client, and "Clear ticks" wiped everyone's. Changing the package
/// model would be a schema change for LIFT too, so the client lives here.
///
/// Named so it cannot collide with any `LiftCore` entity: SwiftData identifies
/// an entity by its class's simple name, not module-qualified (see CLAUDE.md,
/// "`ClientFoodEntry`, and why it is not `FoodEntry`").
///
/// `clientID` is `Client.id`, a plain value like `ScheduledSession.clientID`.
@Model
final class ClientShoppingCheck {
    var id: UUID = UUID()
    var clientID: String = ""
    /// `ShoppingListLine.key`, exactly as `LiftCore.ShoppingList.build`
    /// derived it. Never normalised again here: the package owns that rule,
    /// and a second copy of it could only drift.
    var itemKey: String = ""
    var checkedAt: Date = Date.now

    init(clientID: String, itemKey: String, checkedAt: Date = .now) {
        self.id = UUID()
        self.clientID = clientID
        self.itemKey = itemKey
        self.checkedAt = checkedAt
    }
}

extension ClientShoppingCheck {

    /// Whether `line` is ticked for this client.
    static func isChecked(_ line: ShoppingListLine, clientID: String,
                          in checks: [ClientShoppingCheck]) -> Bool {
        checks.contains { $0.clientID == clientID && $0.itemKey == line.key }
    }

    /// This client's ticks, and nobody else's.
    static func checks(for clientID: String, in checks: [ClientShoppingCheck]) -> [ClientShoppingCheck] {
        checks.filter { $0.clientID == clientID }
    }

    /// Ticks or unticks `line` for one client.
    static func toggle(_ line: ShoppingListLine, clientID: String,
                       in checks: [ClientShoppingCheck], context: ModelContext) {
        let mine = checks.filter { $0.clientID == clientID && $0.itemKey == line.key }
        if mine.isEmpty {
            context.insert(ClientShoppingCheck(clientID: clientID, itemKey: line.key))
        } else {
            for check in mine { context.delete(check) }
        }
    }

    /// "Clear ticks" for one client. Other clients' baskets are untouched.
    static func clear(clientID: String, in checks: [ClientShoppingCheck], context: ModelContext) {
        for check in checks where check.clientID == clientID { context.delete(check) }
    }
}
