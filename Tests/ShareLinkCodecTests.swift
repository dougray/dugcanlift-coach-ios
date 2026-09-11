import XCTest
@testable import Coach

final class ShareLinkCodecTests: XCTestCase {

    /// A hand-built, valid v1 payload matching SHARE-FORMAT.md's own
    /// documented example, base64url-encoded uncompressed ("1u" codec) so
    /// this test has no dependency on DEFLATE round-tripping correctly —
    /// that's covered separately below.
    private func uncompressedFragment(json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let base64url = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "1u" + base64url
    }

    func testDecodesUncompressedMinimalPayload() throws {
        let json: [String: Any] = [
            "v": 1,
            "c": ["i": "b7f3a1c8", "n": "Jordan Reyes", "u": "lb", "p": "ios"],
            "r": "2026-06-24",
            "t": "2026-08-19",
            "z": 1_755_600_000,
            "x": [String](),
            "d": [[String: Any]](),
        ]
        let fragment = try uncompressedFragment(json: json)

        let payload = try ShareLinkCodec.decode(fragment: fragment)

        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.c.i, "b7f3a1c8")
        XCTAssertEqual(payload.c.n, "Jordan Reyes")
        XCTAssertEqual(payload.c.u, "lb")
        XCTAssertEqual(payload.r, "2026-06-24")
        XCTAssertEqual(payload.t, "2026-08-19")
        XCTAssertTrue(payload.d.isEmpty)
        XCTAssertNil(payload.fd)
        XCTAssertNil(payload.g)
    }

    func testDecodesFullLinkURLNotJustFragment() throws {
        let json: [String: Any] = [
            "v": 1, "c": ["i": "x", "n": "X", "u": "lb", "p": "ios"],
            "r": "2026-09-01", "t": "2026-09-10", "z": 1, "x": [String](), "d": [[String: Any]](),
        ]
        let fragment = try uncompressedFragment(json: json)
        let fullLink = "https://www.dugcanlift.com/coach/#" + fragment

        let payload = try ShareLinkCodec.decode(link: fullLink)
        XCTAssertEqual(payload.c.i, "x")
    }

    func testDecodesDayWithWorkoutAndTrimmedSetTuple() throws {
        let json: [String: Any] = [
            "v": 1, "c": ["i": "x", "n": "X", "u": "lb", "p": "ios"],
            "r": "2026-09-01", "t": "2026-09-10", "z": 1,
            "x": ["Back Squat|Barbell"],
            "d": [
                [
                    "k": 3, "n": "Push Day", "fo": "POWERLIFTING",
                    "w": [[0, [[185, 5, 8]]]],
                ] as [String: Any],
            ],
        ]
        let fragment = try uncompressedFragment(json: json)

        let payload = try ShareLinkCodec.decode(fragment: fragment)

        let day = try XCTUnwrap(payload.d.first)
        XCTAssertEqual(day.k, 3)
        XCTAssertEqual(day.n, "Push Day")
        let entry = try XCTUnwrap(day.w?.first)
        XCTAssertEqual(entry.exerciseIndex, 0)
        let set = try XCTUnwrap(entry.sets.first)
        XCTAssertEqual(set, [185, 5, 8])
    }

    func testDecodesItemizedFoodEntry() throws {
        let json: [String: Any] = [
            "v": 1, "c": ["i": "x", "n": "X", "u": "lb", "p": "ios"],
            "r": "2026-09-01", "t": "2026-09-10", "z": 1, "x": [String](),
            "fd": ["Chicken breast"],
            "d": [
                ["k": 0, "f": [[0, 1, 201, 22, 4, 0, 0, 1]]] as [String: Any],
            ],
        ]
        let fragment = try uncompressedFragment(json: json)

        let payload = try ShareLinkCodec.decode(fragment: fragment)

        XCTAssertEqual(payload.fd, ["Chicken breast"])
        let food = try XCTUnwrap(payload.d.first?.f?.first)
        XCTAssertEqual(food, [0, 1, 201, 22, 4, 0, 0, 1])
    }

    /// A genuinely DEFLATE-compressed fragment — produced by a scratch script
    /// calling the exact same `compression_encode_buffer`/`COMPRESSION_ZLIB`
    /// pair `CoachShare.swift` uses to encode, then independently verified to
    /// inflate back to the JSON below before being pasted here. This is real
    /// interop evidence, not a round-trip through this file's own encoder
    /// (this file has no encoder) and not a hand-typed guess at what
    /// compression produces.
    func testDecodesRealCompressedFragmentFromCoachShareEncoder() throws {
        let fragment = "1zTZDLboMwEEV_xZr1UNnmZVjSl1JVLUorZYFYGOIIBILWQNOU8u8dEimqVzP3js8dzQwlxDPUEEMRHlwtSgUIHbVPvd3rjm3NyQwkfZBU92s1UdUWsCDsIc5mKI4QSx7dePzfEwgHcjOOAl3J0eOoUEiUKPKcvJ4g6evufvu8eXjfvDwSt4GYBs7Z6TRU7E6fSB1GiJUniXe88LJMSh99VDlm0vPRxSgnZCbIEWp1QurzZU1ZF4Tbqi4b07HCGk00hF1Vj4bZujRAQ5byJJeBwwNHemSPV0E5IiLhixZD-F5ZiS4b9vY56fE30bYwbUt-YrqyYqk1w3BVCfxD30LfD873WP4A"

        let payload = try ShareLinkCodec.decode(fragment: fragment)

        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.c.i, "b7f3a1c8")
        XCTAssertEqual(payload.c.n, "Jordan Reyes")
        XCTAssertEqual(payload.r, "2026-06-24")
        XCTAssertEqual(payload.t, "2026-08-19")
        XCTAssertEqual(payload.x, ["Back Squat|Barbell", "Bench Press|Barbell"])
        XCTAssertEqual(payload.fd, ["Chicken breast", "White rice"])

        let day = try XCTUnwrap(payload.d.first)
        XCTAssertEqual(day.k, 12)
        XCTAssertEqual(day.n, "Push Day")
        XCTAssertEqual(day.fo, "POWERLIFTING")
        XCTAssertEqual(try XCTUnwrap(day.bw), 209.4, accuracy: 0.01)
        XCTAssertEqual(day.st, 8421)

        let entries = try XCTUnwrap(day.w)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].exerciseIndex, 0)
        XCTAssertEqual(entries[0].sets, [[225, 5, 8], [245, 3, 9]])
        XCTAssertEqual(entries[1].exerciseIndex, 1)
        XCTAssertEqual(entries[1].sets, [[185, 5, 7]])

        let food = try XCTUnwrap(day.f?.first)
        XCTAssertEqual(food, [0, 1, 320, 40, 8, 12, 2, 1])
    }

    func testMalformedFragmentThrows() {
        XCTAssertThrowsError(try ShareLinkCodec.decode(fragment: "x"))
    }

    func testUnsupportedVersionThrows() throws {
        let json: [String: Any] = ["v": 1, "c": ["i": "x", "n": "X", "u": "lb", "p": "ios"],
                                    "r": "a", "t": "b", "z": 1, "x": [String](), "d": [[String: Any]]()]
        let fragment = try uncompressedFragment(json: json)
        let badVersion = "9" + fragment.dropFirst()
        XCTAssertThrowsError(try ShareLinkCodec.decode(fragment: badVersion)) { error in
            guard case ShareLinkError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testUnsupportedCodecThrows() throws {
        let json: [String: Any] = ["v": 1, "c": ["i": "x", "n": "X", "u": "lb", "p": "ios"],
                                    "r": "a", "t": "b", "z": 1, "x": [String](), "d": [[String: Any]]()]
        let fragment = try uncompressedFragment(json: json)
        let badCodec = "1x" + fragment.dropFirst(2)
        XCTAssertThrowsError(try ShareLinkCodec.decode(fragment: badCodec)) { error in
            guard case ShareLinkError.unsupportedCodec = error else {
                return XCTFail("expected unsupportedCodec, got \(error)")
            }
        }
    }
}
