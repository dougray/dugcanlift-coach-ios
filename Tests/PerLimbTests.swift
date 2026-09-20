import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// Per-limb sets: the side column, the two wire formats it arrives in, the
/// grouping key it joins, and the imbalance figure read off the result.
///
/// The rule under all of it is that **absent is "both"**. Every set Coach has
/// stored before this has no side, every link and backup written before it
/// has no side in it, and all of them keep meaning exactly what they meant.
///
/// The maths is a port of LIFT web's `lift/sides.js` by way of lift-ios's
/// `LiftProgression`; `testImbalanceAgreesWithTheReferenceImplementation`
/// checks the port against a case computed by hand from that source.
final class PerLimbTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(CoachSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func payload(days: [WireDay], exercises: [String] = ["Bulgarian Split Squat|Dumbbell"])
        -> ShareLinkPayload {
        ShareLinkPayload(
            v: 1,
            c: WireClient(i: "b7f3a1c8", n: "Jordan Reyes", s: nil, a: nil, h: nil, u: "lb", p: "ios"),
            g: nil, r: "2026-09-01", t: "2026-09-10", z: 1, x: exercises, fd: nil, d: days
        )
    }

    private func day(_ offset: Int, sets: [[Double?]]) -> WireDay {
        WireDay(k: offset, n: nil, fo: nil, bw: nil, st: nil,
                w: [WireWorkoutEntry(exerciseIndex: 0, sets: sets)], ft: nil, f: nil)
    }

    // MARK: - flags is a bitfield: mask, never compare

    /// Every value an encoder can write. Android has no warmup flag on its set
    /// model at all and only ever sends 0, 2 or 4; the iPhone and the browser
    /// can also send 1, 3 and 5. A decoder handles all of them and never
    /// infers the platform from the byte.
    func testFlagsAreMaskedNotCompared() {
        let cases: [(Int, Bool, SetSide?)] = [
            (0, false, nil),        // an ordinary two-sided working set
            (1, true,  nil),        // warmup, as every pre-per-limb encoder wrote it
            (2, false, .left),      // a left working set -- `flags == 1` called this a warmup's opposite by luck
            (3, true,  .left),      // a left warmup -- `flags == 1` called this a working set, wrongly
            (4, false, .right),
            (5, true,  .right),
        ]
        for (flags, warmup, side) in cases {
            XCTAssertEqual(SetFlags.isWarmup(flags), warmup, "warmup bit of \(flags)")
            XCTAssertEqual(SetFlags.side(flags), side, "side bits of \(flags)")
        }
    }

    /// `3` in bits 1-2 is never written. Reading it as both rather than as a
    /// side means a bit added later cannot quietly turn a two-sided set into
    /// a left one.
    func testAnUndefinedSideBitPatternReadsAsBoth() {
        XCTAssertNil(SetFlags.side(0b110), "bits 1-2 == 3 is not a side")
        XCTAssertNil(SetFlags.side(0b111), "and still is not, with the warmup bit set")
    }

    func testFlagsRoundTripThroughTheByte() {
        for side in [nil, SetSide.left, SetSide.right] {
            for warmup in [false, true] {
                let flags = SetFlags.make(isWarmup: warmup, side: side)
                XCTAssertEqual(SetFlags.side(flags), side)
                XCTAssertEqual(SetFlags.isWarmup(flags), warmup)
            }
        }
        XCTAssertEqual(SetFlags.make(isWarmup: false, side: nil), 0,
                       "both with no warmup is a zero byte, which an encoder trims away")
        XCTAssertEqual(SetFlags.make(isWarmup: true, side: .left), 0b011)
        XCTAssertEqual(SetFlags.make(isWarmup: false, side: .right), 0b100)
    }

    // MARK: - SHARE-FORMAT: decoding a link

    func testALinkWithSideBitsDecodesToTheRightSides() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8, nil, nil, nil, 2],     // left
                          [95, 8, nil, nil, nil, 4],     // right
                          [45, 10, nil, nil, nil, 3]])   // left warmup
        ]), into: context)

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertEqual(sets.filter { $0.side == .left && !$0.isWarmup }.count, 1)
        XCTAssertEqual(sets.filter { $0.side == .right }.count, 1)
        let warmup = try XCTUnwrap(sets.first { $0.isWarmup })
        XCTAssertEqual(warmup.side, .left, "a warmup's side is still its side")
        XCTAssertEqual(warmup.weightLb, 45)
    }

    /// A link written before per-limb logging has no flags byte at all, and
    /// one written by a build that only ever set the warmup bit has a 1.
    func testAPreSideLinkDecodesAsBoth() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[185, 5, 8], [135, 5, nil, nil, nil, 1]])
        ]), into: context)

        let sets = try context.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertEqual(sets.count, 2)
        XCTAssertTrue(sets.allSatisfy { $0.side == nil }, "no bits is both, forever")
        XCTAssertEqual(sets.filter(\.isWarmup).count, 1, "and the warmup bit still reads")
    }

    /// The whole reason side rides in `flags` rather than a seventh position:
    /// weight and reps are untouched, so volume is right either way.
    func testSideBitsLeaveWeightAndRepsAlone() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8, 7, 45, 400, 4]])
        ]), into: context)

        let set = try XCTUnwrap(try context.fetch(FetchDescriptor<ExerciseSet>()).first)
        XCTAssertEqual(set.weightLb, 95)
        XCTAssertEqual(set.reps, 8)
        XCTAssertEqual(set.rpe, 7)
        XCTAssertEqual(set.durationSec, 45)
        XCTAssertEqual(set.distanceMeters, 400)
        XCTAssertEqual(set.side, .right)
    }

    /// Both sides are real work. A per-side set counts its weight and reps in
    /// the day's volume exactly as an unmarked one does.
    func testVolumeCountsBothSides() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8, nil, nil, nil, 2], [95, 8, nil, nil, nil, 4]])
        ]), into: context)

        let day = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingDay>()).first)
        let volume = day.sets.reduce(0.0) { total, set in
            set.isWarmup ? total : total + (set.weightLb ?? 0) * Double(set.reps ?? 0)
        }
        XCTAssertEqual(volume, 95 * 8 * 2, "one leg at a time is still two sets of work")
    }

    // MARK: - BACKUP-FORMAT: a named field, omitted when both

    func testBackupRoundTripsEachSide() throws {
        let context = try makeContext()
        let client = Client(id: "c1", name: "Jordan", displayUnit: "lb", platform: "ios")
        context.insert(client)
        let trainingDay = TrainingDay(client: client, dayKey: "2026-09-01")
        context.insert(trainingDay)
        client.trainingDays.append(trainingDay)
        for (side, weight) in [(SetSide.left, 95.0), (SetSide.right, 100.0), (nil as SetSide?, 185.0)] {
            let set = ExerciseSet(day: trainingDay, exerciseName: "Bulgarian Split Squat",
                                  equipment: "Dumbbell", weightLb: weight, reps: 8, side: side)
            context.insert(set)
            trainingDay.sets.append(set)
        }
        try context.save()

        let data = try BackupCodec.export(from: context, defaults: scratchDefaults())

        // Omitted when both -- not "both", not null, not a bit.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"side\":\"left\""))
        XCTAssertTrue(json.contains("\"side\":\"right\""))
        XCTAssertFalse(json.contains("\"both\""))

        let restored = try makeContext()
        try BackupCodec.restore(from: data, into: restored, defaults: scratchDefaults())
        let sets = try restored.fetch(FetchDescriptor<ExerciseSet>())
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets.first { $0.weightLb == 95 }?.side, .left)
        XCTAssertEqual(sets.first { $0.weightLb == 100 }?.side, .right)
        XCTAssertNil(sets.first { $0.weightLb == 185 }?.side)
    }

    /// Leniency this file asks for everywhere: an unrecognised string is both,
    /// not a failed import, and a file written before the field has no key.
    func testAnUnrecognisedOrAbsentBackupSideReadsAsBoth() {
        XCTAssertEqual(SetSide.fromBackup("left"), .left)
        XCTAssertEqual(SetSide.fromBackup(" Right "), .right, "trimmed and lowercased")
        XCTAssertNil(SetSide.fromBackup("both"))
        XCTAssertNil(SetSide.fromBackup("L"))
        XCTAssertNil(SetSide.fromBackup(""))
        XCTAssertNil(SetSide.fromBackup(nil))
    }

    func testABackupWrittenBeforeSidesStillRestores() throws {
        let json = """
        {"v":2,"clients":[{"id":"c1","name":"Jordan","displayUnit":"lb","platform":"ios",
        "lastImportedAt":780000000,"days":[{"dayKey":"2026-09-01","sets":[
        {"exerciseName":"Back Squat","equipment":"Barbell","weightLb":225,"reps":5,"isWarmup":false}],
        "foodEntries":[]}]}]}
        """
        let context = try makeContext()
        try BackupCodec.restore(from: Data(json.utf8), into: context, defaults: scratchDefaults())

        let set = try XCTUnwrap(try context.fetch(FetchDescriptor<ExerciseSet>()).first)
        XCTAssertEqual(set.weightLb, 225)
        XCTAssertNil(set.side, "a file with no side field is a file of two-sided sets")
    }

    // MARK: - Grouping

    func testSideJoinsNameAndEquipmentInTheKey() {
        let left = ClientDisplay.liftKey(name: "Row", equipment: "Dumbbell", side: .left)
        let right = ClientDisplay.liftKey(name: "Row", equipment: "Dumbbell", side: .right)
        let both = ClientDisplay.liftKey(name: "Row", equipment: "Dumbbell")
        XCTAssertNotEqual(left, right, "two limbs must never land in one series")
        XCTAssertNotEqual(left, both)
        XCTAssertEqual(both, "Row|Dumbbell|", "a two-sided lift keeps the key it always had, plus an empty side")
    }

    func testGroupingKeepsSidesApart() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8, nil, nil, nil, 2], [100, 8, nil, nil, nil, 4]]),
            day(2, sets: [[95, 8, nil, nil, nil, 2], [100, 8, nil, nil, nil, 4]]),
        ]), into: context)

        let days = try context.fetch(FetchDescriptor<TrainingDay>())
        let lifts = LiftProgression.byLift(in: days)
        XCTAssertEqual(lifts.count, 1, "one lift, drawn as one card")
        XCTAssertEqual(lifts[0].series.map(\.side), [.left, .right],
                       "two series, in a fixed order so a legend never reshuffles")
        XCTAssertTrue(lifts[0].hasSides)
        XCTAssertEqual(lifts[0].series[0].points.count, 2, "one point a day, not one a set")
    }

    func testATwoSidedLiftIsUnchanged() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[185, 5], [195, 5]]),
            day(1, sets: [[200, 5]]),
        ], exercises: ["Back Squat|Barbell"]), into: context)

        let lifts = LiftProgression.byLift(in: try context.fetch(FetchDescriptor<TrainingDay>()))
        XCTAssertEqual(lifts.count, 1)
        XCTAssertEqual(lifts[0].series.count, 1, "one series")
        XCTAssertNil(lifts[0].series[0].side)
        XCTAssertFalse(lifts[0].hasSides, "and no imbalance figure to show")
        XCTAssertNil(lifts[0].imbalance)
        // The best set of a day is that day's point: 195 * (1 + 5/30).
        XCTAssertEqual(lifts[0].series[0].points.first?.estimatedOneRepMaxLb ?? 0,
                       195 * (1 + 5.0 / 30), accuracy: 0.0001)
    }

    /// A client who turned per-side logging on halfway through really does
    /// have three different things, and merging them would invent a history.
    ///
    /// The unmarked sets are **drawn, not dropped** -- a third series labelled
    /// "Both", as Coach web draws it. They are real sets, and leaving them out
    /// of the chart would lose training that happened.
    func testAnUnmarkedRunAndASidedRunAreThreeSeries() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8]]),
            day(1, sets: [[95, 8, nil, nil, nil, 2], [95, 8, nil, nil, nil, 4]]),
        ]), into: context)

        let lift = try XCTUnwrap(
            LiftProgression.byLift(in: try context.fetch(FetchDescriptor<TrainingDay>())).first)
        XCTAssertEqual(lift.series.map(\.side), [nil, .left, .right],
                       "fixed order, so a legend never reshuffles")
        XCTAssertEqual(lift.series.map(\.label), ["Both", "Left", "Right"])
        XCTAssertEqual(lift.series[0].points.count, 1, "the unmarked day is kept, not dropped")
        // Which is why "Both" needs a colour of its own beside them: drawn in
        // the accent, it would be the same red as Left.
        XCTAssertTrue(lift.hasBothAlongsideSides)
    }

    /// A line needs two points, and Coach web filters its chart and legend on
    /// exactly that -- a legend swatch for a line nobody can see is worse than
    /// no swatch. The figure is not filtered: a side with one session still
    /// counts in "1 left, 3 right so far".
    func testAChartDrawsOnlySeriesWithTwoPointsWhileTheCountStillSeesThem() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[95, 8]]),                                          // one unmarked day
            day(1, sets: [[95, 8, nil, nil, nil, 2], [100, 8, nil, nil, nil, 4]]),
            day(3, sets: [[95, 8, nil, nil, nil, 2], [100, 8, nil, nil, nil, 4]]),
        ]), into: context)

        let lift = try XCTUnwrap(
            LiftProgression.byLift(in: try context.fetch(FetchDescriptor<TrainingDay>())).first)
        XCTAssertEqual(lift.series.map(\.label), ["Both", "Left", "Right"])
        XCTAssertEqual(lift.plottedSeries.map(\.label), ["Left", "Right"],
                       "a one-session series has no line to draw")

        let imbalance = try XCTUnwrap(lift.imbalance)
        XCTAssertEqual(imbalance.detail, "Needs 3 sessions a side · 2 left, 2 right so far")
    }

    /// And a lift that is only ever two-sided has no third line to colour --
    /// its single series keeps the accent every other chart on the page uses.
    func testATwoSidedLiftNeedsNoSeparateBothColour() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [day(0, sets: [[185, 5]])],
                                                    exercises: ["Back Squat|Barbell"]), into: context)

        let lift = try XCTUnwrap(
            LiftProgression.byLift(in: try context.fetch(FetchDescriptor<TrainingDay>())).first)
        XCTAssertFalse(lift.hasSides)
        XCTAssertFalse(lift.hasBothAlongsideSides)
        XCTAssertEqual(lift.series.map(\.label), ["Both"])
    }

    func testWarmupsAreExcludedFromProgressionOnEitherSide() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(payload(days: [
            day(0, sets: [[45, 10, nil, nil, nil, 3]])   // a left-side warmup, and nothing else
        ]), into: context)

        let lifts = LiftProgression.byLift(in: try context.fetch(FetchDescriptor<TrainingDay>()))
        XCTAssertTrue(lifts.isEmpty, "a warmup is not a working set on any limb")
    }

    // MARK: - The imbalance figure

    private func points(_ values: [Double]) -> [LiftSessionPoint] {
        values.enumerated().map {
            LiftSessionPoint(dayKey: String(format: "2026-09-%02d", $0.offset + 1),
                             estimatedOneRepMaxLb: $0.element)
        }
    }

    func testAFigureNeedsThreeSessionsASide() {
        let short = LiftProgression.imbalance(left: points([100, 100]), right: points([90, 90, 90]))
        XCTAssertFalse(short.enough, "two sessions on one side is one heavy day away from meaningless")
        XCTAssertFalse(LiftProgression.imbalance(left: points([100, 100, 100]),
                                                  right: points([90, 90])).enough)
        XCTAssertFalse(LiftProgression.imbalance(left: [], right: []).enough)
        XCTAssertTrue(LiftProgression.imbalance(left: points([100, 100, 100]),
                                                 right: points([90, 90, 90])).enough)
    }

    /// Coach web's `imbalanceLines`, word for word: an em dash rather than a
    /// number nobody can stand behind, and a line saying what is missing.
    func testNotEnoughDataSaysWhatIsMissing() {
        let imbalance = LiftProgression.imbalance(left: points([100, 100]), right: points([90, 90]))
        XCTAssertEqual(imbalance.headline, "—")
        XCTAssertEqual(imbalance.detail, "Needs 3 sessions a side · 2 left, 2 right so far")
        XCTAssertEqual(imbalance.leftSessions, 2)
        XCTAssertEqual(imbalance.rightSessions, 2)
    }

    func testTheFigureIsTheMeanOfTheLastThreeSessionsNotTheBestDay() {
        // A single monster left session early on must not follow the client
        // around forever: only the last three sessions count.
        let imbalance = LiftProgression.imbalance(left: points([400, 100, 100, 100]),
                                                  right: points([100, 100, 100, 100]))
        XCTAssertEqual(imbalance.percent, 0, accuracy: 0.0001)
        XCTAssertNil(imbalance.strongerSide, "a dead heat has no stronger side")
    }

    func testTheGapIsStrongMinusWeakOverStrong() {
        let imbalance = LiftProgression.imbalance(left: points([100, 100, 100]),
                                                  right: points([90, 90, 90]))
        XCTAssertEqual(imbalance.percent, 10, accuracy: 0.0001)
        XCTAssertEqual(imbalance.strongerSide, .left)
        XCTAssertEqual(imbalance.headline, "Left ahead by 10%")
    }

    /// Coach web rounds to a tenth and JavaScript drops a trailing zero, so
    /// "5%" is the web's own output and a Swift `%.1f` would say "5.0%".
    func testThePercentReadsAsTheWebPrintsIt() {
        // 80,80,80 then 95,95,95 against a flat 100: last three 95 vs 100.
        let round = LiftProgression.imbalance(left: points([80, 80, 80, 95, 95, 95]),
                                              right: points([100, 100, 100, 100, 100, 100]))
        XCTAssertEqual(round.headline, "Right ahead by 5%")
        XCTAssertEqual(round.detail,
                       "Mean estimated 1RM of the last 3 sessions each · gap closing")

        let tenth = LiftProgression.imbalance(left: points([94.7, 94.7, 94.7]),
                                              right: points([100, 100, 100]))
        XCTAssertEqual(tenth.headline, "Right ahead by 5.3%")
    }

    func testAPerfectlyBalancedPairIsLevel() {
        let imbalance = LiftProgression.imbalance(left: points([100, 100, 100]),
                                                  right: points([100, 100, 100]))
        XCTAssertEqual(imbalance.percent, 0)
        XCTAssertNil(imbalance.strongerSide)
        XCTAssertEqual(imbalance.headline, "Sides level", "not 'ahead by 0%'")
    }

    func testATrendNeedsFourSessionsASide() {
        let three = LiftProgression.imbalance(left: points([100, 100, 100]),
                                              right: points([90, 90, 90]))
        XCTAssertEqual(three.trend, .notEnoughData,
                       "with three, the first three and the last three are the same sessions")
        XCTAssertNil(three.previousPercent)
        XCTAssertEqual(three.detail, "Mean estimated 1RM of the last 3 sessions each",
                       "and no clause about a gap nobody can judge")
    }

    func testATrendWidensClosesOrHoldsSteady() throws {
        // First three: 100 vs 83.33, a 16.7% gap. Last three: 100 vs 80, 20%.
        let widening = LiftProgression.imbalance(left: points([100, 100, 100, 100]),
                                                 right: points([90, 80, 80, 80]))
        XCTAssertEqual(widening.trend, .widening)
        XCTAssertEqual(widening.detail,
                       "Mean estimated 1RM of the last 3 sessions each · gap widening")
        XCTAssertEqual(widening.percent, 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(widening.previousPercent), 16.6666667, accuracy: 0.0001)

        let closing = LiftProgression.imbalance(left: points([100, 100, 100, 100]),
                                                right: points([80, 90, 100, 100]))
        XCTAssertEqual(closing.trend, .closing)

        let steady = LiftProgression.imbalance(left: points([100, 100, 100, 100]),
                                               right: points([90, 90, 90, 90]))
        XCTAssertEqual(steady.trend, .steady)
        XCTAssertEqual(steady.detail,
                       "Mean estimated 1RM of the last 3 sessions each · gap steady")
    }

    /// Tracked and shown, never targeted -- the same check Coach web's own
    /// tests make on these two strings.
    func testNothingInTheseLinesTellsACoachWhatToDo() {
        let lines = [
            LiftProgression.imbalance(left: points([100, 100]), right: points([90, 90])),
            LiftProgression.imbalance(left: points([100, 100, 100, 100]),
                                      right: points([90, 80, 80, 80])),
        ].map { "\($0.headline) \($0.detail)" }.joined(separator: " ").lowercased()
        for word in ["should", "fix", "warning", "target", "too ", "concern"] {
            XCTAssertFalse(lines.contains(word), "\"\(word)\" has no business in this card")
        }
    }

    /// Half a percentage point of movement is noise in an estimate built out
    /// of an estimate.
    func testMovementInsideHalfAPercentagePointIsSteady() throws {
        // First three mean: left 100, right 99.6 -> gap 0.4%. Last three:
        // left 100, right 100 -> gap 0. Moved -0.4, inside the band.
        let imbalance = LiftProgression.imbalance(left: points([100, 100, 100, 100]),
                                                  right: points([98.8, 100, 100, 100]))
        XCTAssertEqual(try XCTUnwrap(imbalance.previousPercent), 0.4, accuracy: 0.0001)
        XCTAssertEqual(imbalance.trend, .steady)
    }

    /// A session that recorded nothing usable is an absence, not a light day.
    func testAZeroSessionIsDroppedRatherThanAveragedIn() {
        let imbalance = LiftProgression.imbalance(left: points([100, 100, 0]),
                                                  right: points([90, 90, 90]))
        XCTAssertFalse(imbalance.enough, "two usable left sessions is not three")
        XCTAssertEqual(imbalance.leftSessions, 2)
    }

    /// The port checked against the reference it came from. Worked through
    /// `sides.js`'s `imbalance()` by hand with the same input:
    /// last three left = (110+112+114)/3 = 112, right = (100+104+108)/3 = 104,
    /// gap = (112-104)/112 = 0.0714... -> 7.142857%; first three left =
    /// (100+104+110)/3 = 104.666..., right = (96+98+100)/3 = 98, gap =
    /// 6.369426%. Moved +0.77 points, so: widening.
    func testImbalanceAgreesWithTheReferenceImplementation() throws {
        let imbalance = LiftProgression.imbalance(left: points([100, 104, 110, 112, 114]),
                                                  right: points([96, 98, 100, 104, 108]))
        XCTAssertEqual(imbalance.percent, 7.142857142857, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(imbalance.previousPercent), 6.369426751592, accuracy: 0.000001)
        XCTAssertEqual(imbalance.strongerSide, .left)
        XCTAssertEqual(imbalance.trend, .widening)
        XCTAssertEqual(imbalance.headline, "Left ahead by 7.1%")
    }

    /// A card shows the figure only when the lift has both limbs, as Coach
    /// web's does: a client who has only ever logged one side gets no
    /// standing count of what they have not done.
    func testALiftWithOnlyOneSideShowsNoFigureAtAll() {
        let left = LiftSeries(side: .left, points: points([100, 100, 100]))
        XCTAssertNil(LiftProgression.imbalance(in: [left]))
        XCTAssertNil(LiftProgression.imbalance(in: [LiftSeries(side: nil, points: points([100]))]))
        XCTAssertNotNil(LiftProgression.imbalance(
            in: [left, LiftSeries(side: .right, points: points([90, 90, 90]))]))
    }

    // MARK: - Display

    func testAPerSideSetSaysWhichSideAndATwoSidedOneDoesNot() {
        XCTAssertEqual(SetSide.left.shortLabel, "L")
        XCTAssertEqual(SetSide.right.shortLabel, "R")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Row|Dumbbell|left"), "Row (Dumbbell) · Left")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Row|Dumbbell|"), "Row (Dumbbell)")
        XCTAssertEqual(ClientDisplay.liftDisplayName(key: "Row|Dumbbell"), "Row (Dumbbell)",
                       "a two-part key from before this still reads")
    }

    private func scratchDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "PerLimbTests-\(UUID().uuidString)")!
        return defaults
    }
}
