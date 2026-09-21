import Foundation

/// The share extension's hand-off to the app: fragments the coach confirmed in
/// the share sheet, waiting in the App Group's `UserDefaults` suite until Coach
/// next comes to the foreground and imports them.
///
/// Why a queue and not a URL the extension opens: iOS gives a share extension
/// no supported way to open its containing app (`NSExtensionContext.open` is
/// for Today widgets only), and the responder-chain walk to `UIApplication`
/// that some apps use is undocumented. Why not import straight into SwiftData
/// from the extension: Coach's store lives in the app's own container, and
/// moving it into the App Group is a store migration for a feature that does
/// not need one.
///
/// Only fragments cross -- never decoded data -- so the app imports through the
/// exact code path Paste a Link uses. Compiled into both targets; Foundation
/// only.
struct PendingShareLinks {

    /// Declared in both targets' entitlements in project.yml. App Groups sign
    /// on a free Personal Team (lift-ios's widget ships with one); Associated
    /// Domains is the capability that does not.
    static let appGroup = "group.com.dugcanlift.coach"
    static let key = "pendingShareLinkFragments"
    /// A coach sharing more than this many links without opening Coach once
    /// loses the oldest -- a bound so a stuck queue cannot grow forever.
    static let limit = 20

    let defaults: UserDefaults

    /// Nil when the App Group entitlement is missing from the running build.
    /// `UserDefaults(suiteName:)` alone would succeed regardless and write to
    /// a private suite the other process never sees, so the container check
    /// is what proves the two processes really share storage.
    static var shared: PendingShareLinks? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil,
              let defaults = UserDefaults(suiteName: appGroup)
        else { return nil }
        return PendingShareLinks(defaults: defaults)
    }

    /// Queues a fragment. The same link shared twice is queued once.
    func add(_ fragment: String) {
        var queue = pending.filter { $0 != fragment }
        queue.append(fragment)
        defaults.set(Array(queue.suffix(Self.limit)), forKey: Self.key)
    }

    /// Everything queued, oldest first, and empties the queue.
    func takeAll() -> [String] {
        let queue = pending
        if !queue.isEmpty { defaults.removeObject(forKey: Self.key) }
        return queue
    }

    var pending: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }
}
