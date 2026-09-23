import Foundation

/// The window a client has actually sent, as day keys. A day inside it with
/// nothing logged is a day they did not train; a day outside it is a day
/// Coach knows nothing about, and the two must never be said the same way.
struct CoveredRange: Equatable {
    var from: String
    var to: String

    func covers(_ dayKey: String) -> Bool { dayKey >= from && dayKey <= to }
}

/// How a link's own window is folded into what a client has sent before.
///
/// The union, which is Coach web's rule (`app.js`'s `absorb`). Its cost is
/// stated rather than hidden: two imports with a gap between their windows
/// read that gap as covered, so a client who sends twice a year has a stretch
/// Coach will be wrong about. A client sending weekly has no gap.
enum ClientCoverage {
    static func absorbed(existing: CoveredRange?, link: CoveredRange) -> CoveredRange {
        guard let existing else { return link }
        return CoveredRange(from: min(existing.from, link.from),
                            to: max(existing.to, link.to))
    }
}

extension Client {
    /// The window this client has sent, or nil when nothing says -- a client
    /// imported before Coach recorded it, which is "we do not know" and never
    /// "they logged nothing".
    var covered: CoveredRange? {
        get {
            guard let from = coveredFrom, let to = coveredTo, !from.isEmpty, !to.isEmpty
            else { return nil }
            return CoveredRange(from: min(from, to), to: max(from, to))
        }
        set {
            coveredFrom = newValue?.from
            coveredTo = newValue?.to
        }
    }
}
