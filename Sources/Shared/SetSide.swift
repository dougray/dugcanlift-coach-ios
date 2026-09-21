import Foundation

/// Which limb a client performed a set with.
///
/// **Absent is "both", forever.** Every set Coach has ever stored, and every
/// share link and backup written before per-limb logging existed, records no
/// side at all -- and must keep meaning exactly what it meant: a two-sided
/// lift, or a single-arm lift whose sides nobody recorded. There is
/// deliberately no `.both` case to write into a column by accident; `nil` is
/// the value, so a store written before this reads correctly with no
/// migration and nothing is ever guessed from an exercise name.
///
/// A left-arm row and a right-arm row are not the same lift, so side joins
/// name and equipment in `ClientDisplay.liftKey` -- the same reasoning
/// equipment already carries here.
///
/// Ported from lift-ios's `SetSide` and LIFT web's `lift/sides.js`, which are
/// the reference implementations. Do not re-derive the rules.
enum SetSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right

    var id: String { rawValue }

    /// The one character the session log uses: "185 lb × 5 L".
    var shortLabel: String { self == .left ? "L" : "R" }

    var displayName: String { self == .left ? "Left" : "Right" }

    var opposite: SetSide { self == .left ? .right : .left }

    // MARK: - SHARE-FORMAT

    /// This side as bits 1-2 of the set tuple's `flags` byte: 1 left, 2 right.
    /// 0 is both, and `3` is never written.
    var shareFlagBits: Int { self == .left ? 1 : 2 }

    /// `"left"` / `"right"` in a backup file, omitted entirely when both.
    var backupValue: String { rawValue }

    /// Lenient on the way in: an unknown string is both, not a failed import.
    /// A file written before per-limb logging has no key here at all, and
    /// `"both"`, `"L"`, an empty string or junk from another app all read as
    /// both -- the only safe reading of a set whose side nobody stated.
    static func fromBackup(_ raw: String?) -> SetSide? {
        guard let raw else { return nil }
        return SetSide(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// The set tuple's sixth field, which is a **bitfield and must be masked,
/// never compared**.
///
/// Bit 0 is warmup and bits 1-2 are the side (SHARE-FORMAT.md "flags"). A
/// build that tested `flags == 1` for warmup was right while warmup was the
/// only bit; it now calls a left-side working set (2) a working set by luck
/// and a left-side warmup (3) a working set wrongly. Android sends 0, 2 or 4
/// because its set model has no warmup flag at all, and only the iPhone and
/// the browser can send 3 or 5 -- a decoder handles all of them and never
/// infers the platform from the byte.
enum SetFlags {
    static let warmupBit = 1
    static let sideShift = 1
    static let sideMask = 0b11

    static func isWarmup(_ flags: Int) -> Bool { flags & warmupBit == warmupBit }

    /// Bits 1-2, or nil for both. `3` is not a side: like `0` it reads as
    /// both, so a bit added later cannot quietly turn a two-sided set into a
    /// left one.
    static func side(_ flags: Int) -> SetSide? {
        switch (flags >> sideShift) & sideMask {
        case 1:  return .left
        case 2:  return .right
        default: return nil
        }
    }

    /// The byte an encoder would write for this set. Coach does not encode
    /// logged sets -- PLAN-FORMAT prescribes, it does not log -- but the
    /// round-trip tests need the other half of the contract, and one place
    /// holding both halves is how they stay in agreement.
    static func make(isWarmup: Bool, side: SetSide?) -> Int {
        (isWarmup ? warmupBit : 0) | ((side?.shareFlagBits ?? 0) << sideShift)
    }
}
