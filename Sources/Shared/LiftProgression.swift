import Foundation

/// One session's best estimated 1RM for one side of one lift, in **pounds**.
///
/// A day, not a set: two sides on the same date are two points on two lines,
/// and three sets of the same side on one date are one point. "Sessions" in
/// the imbalance rule below means days, which is the unit a coach counts in.
struct LiftSessionPoint: Hashable, Sendable {
    var dayKey: String
    var estimatedOneRepMaxLb: Double
}

/// The L and R lines for one lift, or the single line a two-sided lift has.
struct LiftSeries: Identifiable, Sendable {
    var side: SetSide?
    var points: [LiftSessionPoint]

    var id: String { side?.rawValue ?? "both" }

    /// "Left", "Right", or "Both" -- what a legend and a caption name a line.
    var label: String { side?.displayName ?? "Both" }

    /// The best day in the window -- a caption, and nothing more. **The
    /// imbalance figure does not use this**: it averages each side's last
    /// three sessions, because a peak rewards one good day forever.
    var bestOneRepMaxLb: Double? { points.map(\.estimatedOneRepMaxLb).max() }

    /// The mean of the last three sessions -- the number the imbalance figure
    /// is actually computed from, so a view can show its working.
    var recentMeanOneRepMaxLb: Double? {
        let recent = points.suffix(LiftProgression.minimumSessionsPerSide)
            .map(\.estimatedOneRepMaxLb)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }

    var sessionCount: Int { points.count }
}

/// Every series for one lift, and the gap between the two sides when it has
/// them. What one card on the client page draws.
struct LiftProgressionSeries: Identifiable, Sendable {
    /// `"name|equipment"` -- the lift without its side.
    var exerciseKey: String
    var series: [LiftSeries]

    var id: String { exerciseKey }

    /// Whether any set of this lift recorded a side at all. A bench press
    /// never does, and its card is exactly the card it always was.
    var hasSides: Bool { series.contains { $0.side != nil } }

    /// The unmarked series, when this lift has one **and** has sided ones too
    /// -- sets logged before the client turned per-side logging on. They are
    /// real sets and Coach web draws them as a third line, "Both", rather than
    /// dropping them; this says whether that line needs a colour of its own so
    /// it is not the same red as Left.
    var hasBothAlongsideSides: Bool { hasSides && series.contains { $0.side == nil } }

    var imbalance: LiftImbalance? { LiftProgression.imbalance(in: series) }

    /// The series a chart can actually draw: a line needs two points, and a
    /// legend swatch for a line nobody can see is worse than no swatch. Coach
    /// web filters its `plotted` the same way and builds its legend from the
    /// result.
    ///
    /// The imbalance figure is **not** filtered by this — it reads `series`,
    /// so a side with one session still counts toward "2 left, 2 right so
    /// far" rather than vanishing from the count.
    var plottedSeries: [LiftSeries] { series.filter { $0.points.count >= 2 } }
}

/// How far apart a client's two sides are, and which way that is moving.
///
/// **Tracked and shown, never targeted.** There is no threshold in this type,
/// no "high", no colour, and nothing that decides a number is bad -- the same
/// discipline saturated fat, sugar and sodium are held to. A gap of a few per
/// cent is ordinary in most people, an app is not qualified to say what one
/// person's means, and a trainer is.
///
/// `headline` and `detail` are a port of Coach web's `imbalanceLines`
/// (`coach/sides.js`), word for word, so a coach who reads this sentence on
/// one platform reads the same sentence on the others. Two pieces rather than
/// one, so the headline stays short on a phone and "not enough yet" says what
/// is missing rather than nothing.
struct LiftImbalance: Sendable, Equatable {
    /// Whether both sides reached `minimumSessionsPerSide`. False is a real
    /// answer with something to say, not an absence.
    var enough: Bool
    /// Sessions that recorded a usable estimate, per side -- what the "2 left,
    /// 2 right so far" line counts.
    var leftSessions: Int
    var rightSessions: Int
    /// The side whose recent mean is higher, or nil for a dead heat.
    var strongerSide: SetSide?
    /// `(strong − weak) / strong`, in percentage points. 0 when there is no
    /// figure to show.
    var percent: Double
    /// The same figure over the window's *first* three sessions, when there
    /// were enough sessions to compute one. `trend` compares against it.
    var previousPercent: Double?
    var trend: Trend

    /// Whether the gap is getting bigger or smaller across the window.
    ///
    /// `.notEnoughData` rather than a guess: with exactly three sessions the
    /// first three and the last three are the same sessions, so "steady"
    /// would be arithmetic rather than an observation.
    enum Trend: Sendable, Equatable {
        case widening, closing, steady, notEnoughData

        /// The word the detail line prints after "gap ". Coach web's own
        /// values (`widening` / `closing` / `steady`), not a rephrasing.
        var word: String? {
            switch self {
            case .widening:      return "widening"
            case .closing:       return "closing"
            case .steady:        return "steady"
            case .notEnoughData: return nil
            }
        }
    }

    /// "5.3%", and "5%" for a round one -- Coach web rounds to a tenth and
    /// JavaScript drops the trailing zero, so a Swift `%.1f` would print
    /// "5.0%" where the web says "5%".
    var percentText: String {
        let rounded = (percent * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))%" : String(format: "%.1f%%", rounded)
    }

    /// "Right ahead by 5.3%", "Sides level" for a dead heat, or "—" when
    /// there is no figure -- an em dash rather than a number nobody can
    /// stand behind.
    var headline: String {
        guard enough else { return "—" }
        guard let strongerSide else { return "Sides level" }
        return "\(strongerSide.displayName) ahead by \(percentText)"
    }

    /// "Mean estimated 1RM of the last 3 sessions each · gap closing", with
    /// the clause absent when the trend cannot be judged, or "Needs 3
    /// sessions a side · 2 left, 2 right so far".
    var detail: String {
        guard enough else {
            return "Needs \(LiftProgression.minimumSessionsPerSide) sessions a side · "
                + "\(leftSessions) left, \(rightSessions) right so far"
        }
        let basis = "Mean estimated 1RM of the last \(LiftProgression.minimumSessionsPerSide) sessions each"
        return trend.word.map { "\(basis) · gap \($0)" } ?? basis
    }
}

/// Grouping and imbalance for the client page's lift progression.
///
/// A plain enum of static functions with no view and no SwiftUI import, for
/// the reason `MacroFields` and `LinkImportMacros` are value types in Cook: a
/// rule living in a view's `@State` cannot be tested, and this one decides
/// what a trainer is told about a client's body.
///
/// **This is a cross-platform rule, not a local choice.** LIFT web's
/// `lift/sides.js` is the reference implementation, lift-ios's
/// `LiftProgression` is the direct template for this file, and LIFT Android
/// matches both, so every app prints the same number from the same log.
enum LiftProgression {

    /// How many sessions each side needs before an imbalance figure is shown
    /// at all, and how many are averaged to produce it. A floor on both sides
    /// independently -- six left sessions and two right ones gets no figure,
    /// because the right-hand number would be one bad day away from
    /// meaningless.
    static let minimumSessionsPerSide = 3

    /// Sessions a side needs before a trend is claimed. With exactly three,
    /// the first three and the last three are the same sessions and "steady"
    /// would be arithmetic rather than an observation.
    static let minimumSessionsForTrend = 4

    /// A gap that moves less than this many percentage points across the
    /// window is steady rather than a direction. Half a point is noise in an
    /// estimate built out of an estimate.
    static let steadyBandPercentagePoints = 0.5

    // MARK: - Grouping

    /// Epley, in pounds, for one set -- nil for anything that cannot honestly
    /// produce one. Warmups are excluded here, where that rule already lived,
    /// so nothing downstream has to remember it.
    static func estimatedOneRepMaxLb(_ set: ExerciseSet) -> Double? {
        guard !set.isWarmup, let weight = set.weightLb, weight > 0,
              let reps = set.reps, reps > 0 else { return nil }
        let estimate = weight * (1 + Double(reps) / 30)
        return estimate.isFinite ? estimate : nil
    }

    /// Every lift's series, keyed by `ClientDisplay.liftKey` -- **name,
    /// equipment and side**, so two limbs cannot land in one series by
    /// construction.
    static func allSeries(in days: [TrainingDay]) -> [String: LiftSeries] {
        var buckets: [String: (side: SetSide?, points: [String: Double])] = [:]
        for day in days.sorted(by: { $0.dayKey < $1.dayKey }) {
            for set in day.sets {
                guard let estimate = estimatedOneRepMaxLb(set) else { continue }
                let key = ClientDisplay.liftKey(name: set.exerciseName,
                                                equipment: set.equipment, side: set.side)
                var bucket = buckets[key] ?? (side: set.side, points: [:])
                // One point a day: the best working set of that session, which
                // is what "session" means in the imbalance rule.
                bucket.points[day.dayKey] = max(bucket.points[day.dayKey] ?? 0, estimate)
                buckets[key] = bucket
            }
        }
        return buckets.mapValues { bucket in
            LiftSeries(side: bucket.side,
                       points: bucket.points
                        .map { LiftSessionPoint(dayKey: $0.key, estimatedOneRepMaxLb: $0.value) }
                        .sorted { $0.dayKey < $1.dayKey })
        }
    }

    /// One entry per lift, its series split by side, in the order a card list
    /// should draw them.
    ///
    /// The returned series are `[both]` for a purely two-sided lift, `[left,
    /// right]` for one logged a limb at a time, and can be all three for a
    /// client who turned per-side logging on halfway through -- those really
    /// are three different things and merging them would invent a history.
    /// Order within a lift is fixed (both, left, right) so a legend never
    /// reshuffles between renders.
    static func byLift(in days: [TrainingDay]) -> [LiftProgressionSeries] {
        let order: [SetSide?] = [nil, .left, .right]
        var byExercise: [String: [LiftSeries]] = [:]
        for (key, series) in allSeries(in: days) {
            byExercise[exerciseKey(fromLiftKey: key), default: []].append(series)
        }
        return byExercise
            .map { key, series in
                LiftProgressionSeries(
                    exerciseKey: key,
                    series: order.compactMap { side in series.first { $0.side == side } })
            }
            .sorted { $0.exerciseKey < $1.exerciseKey }
    }

    /// Drops the side from a three-part lift key, leaving `"name|equipment"`.
    static func exerciseKey(fromLiftKey key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return key }
        return "\(parts[0])|\(parts[1])"
    }

    // MARK: - Imbalance

    /// The gap between two sides, from each side's per-session estimated 1RM
    /// across the window the card is already showing:
    ///
    /// - A side's figure is the **mean of its last three sessions**, not its
    ///   best day and not its latest. A single best rewards one good day
    ///   forever; a latest value moves ten points when someone trains tired,
    ///   and either gets read as a finding.
    /// - Shown only when **both** sides have three sessions in the window.
    /// - `trend` compares that against the mean of the **first three**, and
    ///   needs four sessions a side before it says anything at all.
    ///
    /// Nil is a real answer, and the card says so in words ("needs three
    /// sessions a side") rather than showing a figure with a quiet caveat: a
    /// percentage on screen gets read and remembered whatever is printed next
    /// to it.
    static func imbalance(left: [LiftSessionPoint], right: [LiftSessionPoint]) -> LiftImbalance {
        let l = values(left)
        let r = values(right)
        let notYet = LiftImbalance(enough: false, leftSessions: l.count, rightSessions: r.count,
                                   strongerSide: nil, percent: 0, previousPercent: nil,
                                   trend: .notEnoughData)

        guard l.count >= minimumSessionsPerSide, r.count >= minimumSessionsPerSide else { return notYet }

        let nowLeft = mean(l.suffix(minimumSessionsPerSide))
        let nowRight = mean(r.suffix(minimumSessionsPerSide))
        guard let percent = gap(nowLeft, nowRight) else { return notYet }

        let stronger: SetSide? = nowLeft == nowRight ? nil : (nowLeft > nowRight ? .left : .right)

        var previous: Double?
        var trend = LiftImbalance.Trend.notEnoughData
        if l.count >= minimumSessionsForTrend, r.count >= minimumSessionsForTrend,
           let before = gap(mean(l.prefix(minimumSessionsPerSide)),
                            mean(r.prefix(minimumSessionsPerSide))) {
            previous = before
            let moved = percent - before
            trend = moved > steadyBandPercentagePoints ? .widening
                  : moved < -steadyBandPercentagePoints ? .closing
                  : .steady
        }

        return LiftImbalance(enough: true, leftSessions: l.count, rightSessions: r.count,
                             strongerSide: stronger, percent: percent,
                             previousPercent: previous, trend: trend)
    }

    /// Convenience over the series a card already built, so the figure and the
    /// lines above it always describe the same stretch of training.
    ///
    /// Nil when the lift does not have **both** a left and a right series, as
    /// Coach web's card does: a client who has only ever logged one limb of a
    /// lift gets no line about the other, rather than a standing count of what
    /// they have not done.
    static func imbalance(in series: [LiftSeries]) -> LiftImbalance? {
        guard let left = series.first(where: { $0.side == .left }),
              let right = series.first(where: { $0.side == .right })
        else { return nil }
        return imbalance(left: left.points, right: right.points)
    }

    /// `(strong − weak) / strong` in percentage points, or nil when there is
    /// no strong side to divide by.
    static func gap(_ a: Double, _ b: Double) -> Double? {
        let strong = max(a, b), weak = min(a, b)
        guard strong > 0 else { return nil }
        return (strong - weak) / strong * 100
    }

    /// Chronological estimates, dropping any session that recorded nothing
    /// usable -- a zero or a non-finite value is not a light day, it is an
    /// absence, and averaging it in would invent a gap.
    private static func values(_ points: [LiftSessionPoint]) -> [Double] {
        points
            .sorted { $0.dayKey < $1.dayKey }
            .map(\.estimatedOneRepMaxLb)
            .filter { $0.isFinite && $0 > 0 }
    }

    private static func mean(_ values: some Collection<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
