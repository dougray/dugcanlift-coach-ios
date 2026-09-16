import XCTest
import SwiftData
import LiftCore
@testable import Coach

/// A client's runs, walks and hikes, from a link LIFT web wrote
/// (`Tests/Fixtures/outdoor-share-link.txt`, copied from
/// `dugcanlift-site/lift/fixtures`). The expected values are that repo's
/// `outdoor-share-expected.json`, also copied. Never regenerate either from
/// Swift: agreement with Coach's own code would prove nothing.
final class OutdoorShareImportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Client.self, Goal.self, TrainingDay.self, ExerciseSet.self, ClientFoodEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    private func fixturePayload() throws -> ShareLinkPayload {
        let link = try String(contentsOf: fixtureURL("outdoor-share-link", "txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try ShareLinkCodec.decode(link: link)
    }

    private struct Expected: Decodable {
        let o: [WireOutdoorActivity]
        let ob: [WireOutdoorBest]
        let lr: WireLastRoute
        let trimmedPointCount: Int
    }

    private func expected() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: fixtureURL("outdoor-share-expected", "json")))
    }

    private func client(_ context: ModelContext) throws -> Client {
        try XCTUnwrap(try context.fetch(FetchDescriptor<Client>()).first)
    }

    /// The fixture payload with `z` and the outdoor top-level parts replaced.
    private func variant(of p: ShareLinkPayload, z: Int, ob: [WireOutdoorBest]?, lr: WireLastRoute?) -> ShareLinkPayload {
        ShareLinkPayload(v: p.v, c: p.c, g: p.g, r: p.r, t: p.t, z: z, x: p.x, fd: p.fd, d: p.d, ob: ob, lr: lr)
    }

    func testTheWebLinkImportsThreeActivitiesOnTheirDays() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(try fixturePayload(), into: context)

        let days = try client(context).trainingDays.sorted { $0.dayKey < $1.dayKey }
        XCTAssertEqual(days.map(\.dayKey), ["2026-09-10", "2026-09-12", "2026-09-13"])
        XCTAssertEqual(days.flatMap(\.outdoor), try expected().o,
                       "every activity, in day order, exactly as LIFT web encoded them")
        XCTAssertEqual(days[0].outdoor, [WireOutdoorActivity(type: 0, durationSec: 3000, distanceMeters: 10001, climbMeters: 0)])
        XCTAssertEqual(days[1].outdoor.first?.type, 1)
    }

    func testBestsAndLastRouteMatchWhatTheSenderWrote() throws {
        let context = try makeContext()
        try ShareLinkImporter.importPayload(try fixturePayload(), into: context)
        let stored = try client(context)
        let expected = try expected()

        XCTAssertEqual(stored.outdoorBests, expected.ob)
        let run = try XCTUnwrap(stored.outdoorBests?.first { $0.type == 0 })
        XCTAssertEqual(run.count, 2)
        XCTAssertEqual(run.farthestMeters, 10001)
        XCTAssertEqual(run.longestSec, 3000)
        XCTAssertEqual(run.fastestSecPerKm, 300)
        let walk = try XCTUnwrap(stored.outdoorBests?.first { $0.type == 1 })
        XCTAssertNil(walk.fastestSecPerKm, "a 300 m walk sets no pace, and blank stays blank")

        let route = try XCTUnwrap(stored.lastRoute)
        XCTAssertEqual(route, expected.lr)
        XCTAssertEqual(route.distanceMeters, 2795)
        let points = try XCTUnwrap(OutdoorDisplay.routePoints(route))
        XCTAssertEqual(points.count, 150)
        XCTAssertEqual(points.count, expected.trimmedPointCount)
    }

    func testANewerLinkWithoutBestsOrRouteClearsThem() throws {
        let context = try makeContext()
        let original = try fixturePayload()
        try ShareLinkImporter.importPayload(original, into: context)

        try ShareLinkImporter.importPayload(variant(of: original, z: original.z + 60, ob: nil, lr: nil), into: context)

        let stored = try client(context)
        XCTAssertNil(stored.lastRoute, "a client who turned route sharing off expects it gone")
        XCTAssertNil(stored.outdoorBests)
        XCTAssertNil(stored.lastRouteData)
    }

    func testAnOlderLinkDoesNotClearOrReplaceThem() throws {
        let context = try makeContext()
        let original = try fixturePayload()
        try ShareLinkImporter.importPayload(original, into: context)

        try ShareLinkImporter.importPayload(variant(of: original, z: original.z - 86_400, ob: nil, lr: nil), into: context)

        let stored = try client(context)
        XCTAssertEqual(stored.lastRoute, try expected().lr, "a stale link pasted late must not undo a newer one")
        XCTAssertEqual(stored.outdoorBests, try expected().ob)
        XCTAssertEqual(stored.exportedAtEpochSec, original.z)
    }

    func testAClientStoredBeforeOutdoorTakesTheFirstLinkAsNewer() throws {
        let context = try makeContext()
        let existing = Client(id: "outdoor-fixture", name: "Outdoor Fixture", displayUnit: "lb", platform: "web")
        context.insert(existing)
        try context.save()
        XCTAssertNil(existing.exportedAtEpochSec)

        try ShareLinkImporter.importPayload(try fixturePayload(), into: context)
        XCTAssertNotNil(try client(context).lastRoute)
    }

    func testReplacingADayReplacesItsActivities() throws {
        let context = try makeContext()
        let original = try fixturePayload()
        try ShareLinkImporter.importPayload(original, into: context)

        // The same first day, resent with the run deleted at home.
        let emptied = ShareLinkPayload(v: original.v, c: original.c, g: nil, r: original.r, t: original.t,
                                       z: original.z + 1, x: [], fd: nil,
                                       d: [WireDay(k: 0, n: nil, fo: nil, bw: 200, st: nil, w: nil, ft: nil, f: nil)],
                                       ob: original.ob, lr: original.lr)
        try ShareLinkImporter.importPayload(emptied, into: context)

        let day = try XCTUnwrap(try client(context).trainingDays.first { $0.dayKey == "2026-09-10" })
        XCTAssertEqual(day.outdoor, [])
        XCTAssertNil(day.outdoorData, "an empty day stores nothing rather than []")
    }
}

final class OutdoorDisplayTests: XCTestCase {

    func testDistanceUnitFollowsTheWeightUnit() {
        XCTAssertEqual(OutdoorDisplay.distanceUnit(weightUnit: "lb"), "mi")
        XCTAssertEqual(OutdoorDisplay.distanceUnit(weightUnit: "kg"), "km")
    }

    func testDurations() {
        XCTAssertEqual(OutdoorDisplay.durationText(seconds: 1720), "28:40")
        XCTAssertEqual(OutdoorDisplay.durationText(seconds: 3730), "1:02:10")
        XCTAssertEqual(OutdoorDisplay.durationText(seconds: 240), "4:00")
        XCTAssertEqual(OutdoorDisplay.durationOrDash(0), "—")
    }

    func testDistances() {
        XCTAssertEqual(OutdoorDisplay.distanceText(meters: 10001, unit: "mi"), "6.21 mi")
        XCTAssertEqual(OutdoorDisplay.distanceText(meters: 10001, unit: "km"), "10.00 km")
        XCTAssertEqual(OutdoorDisplay.distanceText(meters: 300, unit: "mi"), "0.19 mi")
    }

    func testPaces() {
        XCTAssertEqual(OutdoorDisplay.paceText(secondsPerKm: 300, unit: "mi"), "8:03 /mi")
        XCTAssertEqual(OutdoorDisplay.paceText(secondsPerKm: 300, unit: "km"), "5:00 /km")
        XCTAssertEqual(OutdoorDisplay.activityPace(distanceMeters: 2795, durationSec: 1720, unit: "mi"), "16:30 /mi")
        XCTAssertNil(OutdoorDisplay.activityPace(distanceMeters: 999, durationSec: 240, unit: "mi"),
                     "under 1 km a pace is mostly GPS noise")
        XCTAssertNil(OutdoorDisplay.activityPace(distanceMeters: 5000, durationSec: 0, unit: "mi"))
    }

    func testRoundingMatchesTheWebAppsToFixed() {
        // 2.795 is 2.79499... in binary, and `toFixed(2)` rounds that value,
        // not the decimal: route.js shows "2.79 km", so Coach must too. Checked
        // against route.js under node. Always a "." -- `String(format:)` is
        // not localised, and neither is `toFixed`.
        XCTAssertEqual(OutdoorDisplay.distanceText(meters: 2795, unit: "km"), "2.79 km")
        XCTAssertEqual(OutdoorDisplay.distanceText(meters: 1005, unit: "km"), "1.00 km")
    }

    func testBestsShowADashForNothingAndNeverAZero() {
        let walk = WireOutdoorBest(type: 1, count: 1, farthestMeters: 300, longestSec: 240, fastestSecPerKm: nil)
        XCTAssertEqual(OutdoorDisplay.bestHeading(walk), "Walk · 1 activity")
        let stats = OutdoorDisplay.bestStats(walk, unit: "mi")
        XCTAssertEqual(stats.farthest, "0.19 mi")
        XCTAssertEqual(stats.longest, "4:00")
        XCTAssertEqual(stats.fastest, "—")

        let zero = WireOutdoorBest(type: 0, count: 2, farthestMeters: 0, longestSec: nil, fastestSecPerKm: 0)
        XCTAssertEqual(OutdoorDisplay.bestHeading(zero), "Run · 2 activities")
        XCTAssertEqual(OutdoorDisplay.bestStats(zero, unit: "km").farthest, "—")
        XCTAssertEqual(OutdoorDisplay.bestStats(zero, unit: "km").fastest, "—")
    }

    func testUnknownTypesAreSkippedNotGuessed() {
        let day = [WireOutdoorActivity(type: 7, durationSec: 60, distanceMeters: 100, climbMeters: 0),
                   WireOutdoorActivity(type: 2, durationSec: 3600, distanceMeters: 5000, climbMeters: 300)]
        XCTAssertEqual(OutdoorDisplay.activities(day).map(\.type), [2])
        XCTAssertEqual(OutdoorDisplay.daySummary(day, unit: "km"), "Hike 5.00 km")
        XCTAssertNil(OutdoorDisplay.bests([WireOutdoorBest(type: 9, count: 1, farthestMeters: 1, longestSec: 1, fastestSecPerKm: 1)]))
        XCTAssertNil(OutdoorDisplay.routePoints(WireLastRoute(type: 9, startedAtEpochSec: 0, durationSec: 1,
                                                              distanceMeters: 1, climbMeters: 0, polyline: "_p~iF~ps|U_ulLnnqC")))
    }

    func testARouteOfOnePointIsNothingToDraw() {
        let route = WireLastRoute(type: 0, startedAtEpochSec: 0, durationSec: 1, distanceMeters: 1, climbMeters: 0,
                                  polyline: "_p~iF~ps|U")
        XCTAssertNil(OutdoorDisplay.routePoints(route))
    }

    func testAnOutdoorOnlyDayIsASession() {
        let run = TrainingDay(client: nil, dayKey: "2026-09-13")
        run.outdoor = [WireOutdoorActivity(type: 0, durationSec: 1720, distanceMeters: 2795, climbMeters: 37)]
        let weighIn = TrainingDay(client: nil, dayKey: "2026-09-14", bodyweightLb: 200)
        XCTAssertEqual(ClientDisplay.sessionDays([weighIn, run]).map(\.dayKey), ["2026-09-13"])
    }
}
