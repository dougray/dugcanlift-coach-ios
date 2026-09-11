import Foundation
import Compression

struct ShareLinkPayload: Decodable {
    let v: Int
    let c: WireClient
    let g: WireGoal?
    let r: String
    let t: String
    let z: Int
    let x: [String]
    let fd: [String]?
    let d: [WireDay]
}

struct WireClient: Decodable {
    let i: String
    let n: String
    let s: String?
    let a: Int?
    let h: Double?
    let u: String
    let p: String?
}

struct WireGoal: Decodable {
    let c: Int
    let p: Int
    let f: Int
    let cb: Int
    let fb: Int
}

struct WireDay: Decodable {
    let k: Int
    let n: String?
    let fo: String?
    let bw: Double?
    let st: Int?
    let w: [WireWorkoutEntry]?
    let ft: [Double]?
    let f: [[Double]]?
}

/// A `[exerciseDictIndex, setsArray]` pair. This 2-element array mixes an
/// Int with a nested array, which Codable's automatic array-of-one-type
/// synthesis can't decode — read manually from an unkeyed container instead.
struct WireWorkoutEntry: Decodable {
    let exerciseIndex: Int
    let sets: [[Double?]]

    // Explicit memberwise init: defining `init(from:)` below suppresses
    // Swift's auto-synthesized memberwise init, and Task 3's tests
    // construct this type directly (not just by decoding), so it needs
    // one written out.
    init(exerciseIndex: Int, sets: [[Double?]]) {
        self.exerciseIndex = exerciseIndex
        self.sets = sets
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        exerciseIndex = try container.decode(Int.self)
        sets = try container.decode([[Double?]].self)
    }
}

/// Decodes a client's training-log link (`SHARE-FORMAT.md` v1) into a typed
/// payload. Mirrors `lift-ios`'s `PlanLinkCodec.swift` decode pipeline
/// (base64url, then raw DEFLATE via `COMPRESSION_ZLIB` as a no-wrap codec)
/// but is written independently — a fixture the real `CoachShare.swift`
/// encoder produced, decoded here, exercises interop, not just
/// round-tripping through shared code.
enum ShareLinkCodec {

    static func decode(fragment: String) throws -> ShareLinkPayload {
        guard fragment.count >= 2 else { throw ShareLinkError.malformedFragment }

        let version = fragment[fragment.startIndex]
        let codec = fragment[fragment.index(after: fragment.startIndex)]
        let rest = fragment.dropFirst(2)
        let payloadString = String(rest.prefix { isBase64URLCharacter($0) })

        guard version == "1" else {
            throw ShareLinkError.unsupportedVersion(String(version))
        }

        guard let payloadData = base64URLDecode(payloadString) else {
            throw ShareLinkError.corruptPayload
        }

        let jsonData: Data
        switch codec {
        case "z":
            guard let inflated = inflateRaw(payloadData) else { throw ShareLinkError.corruptPayload }
            jsonData = inflated
        case "u":
            jsonData = payloadData
        default:
            throw ShareLinkError.unsupportedCodec(String(codec))
        }

        let payload: ShareLinkPayload
        do {
            payload = try JSONDecoder().decode(ShareLinkPayload.self, from: jsonData)
        } catch {
            throw ShareLinkError.corruptPayload
        }

        guard payload.v == 1 else { throw ShareLinkError.unsupportedVersion(String(payload.v)) }

        return payload
    }

    /// Accepts a full link or a bare fragment — the "Paste a link" field may
    /// receive either, depending on what the trainer copied.
    static func decode(link: String) throws -> ShareLinkPayload {
        guard let hashIndex = link.firstIndex(of: "#") else {
            return try decode(fragment: link)
        }
        return try decode(fragment: String(link[link.index(after: hashIndex)...]))
    }

    private static func isBase64URLCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    /// Grows the output buffer and retries — `compression_decode_buffer` gives
    /// no way to ask "how big will this be", unlike a streaming API.
    private static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(data.count * 4, 4096)
        let maxCapacity = 16 * 1024 * 1024

        while capacity <= maxCapacity {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }

            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity, base, data.count, nil, COMPRESSION_ZLIB
                )
            }

            if written > 0 && written < capacity {
                return Data(bytes: destination, count: written)
            }
            capacity *= 2
        }
        return nil
    }
}

enum ShareLinkError: Error, Equatable {
    case malformedFragment
    case unsupportedVersion(String)
    case unsupportedCodec(String)
    case corruptPayload
}
