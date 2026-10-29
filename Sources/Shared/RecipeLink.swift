import Foundation
import Compression

/// The "Send to Coach" bookmarklet's link: `dugcanliftcoach://recipe#r1…`.
///
/// A port of `dugcanlift-kit`'s `bookmarklet/recipe-link.mjs`, the reference
/// decoder every build ports, with the same refusals and the same 512 KiB cap
/// (the kit's `bookmarklet/README.md` is the contract). It only unwraps: what
/// comes out is a `SharedRecipePage`, exactly what Safari's share extension
/// produces, so the recipe goes through the same `RecipeJSONLD` reader and the
/// same review. The page's address rides in the link and is never fetched.
///
/// Wire format:
///
///     <target>#r1<base64url(deflate-raw(JSON)), no padding>
///     JSON = {"v":1,"url":"<page address>","jsonld":["<block text>", ...]}
///
/// Refuses, returning nil, rather than guessing: no `r1` prefix, bad
/// base64url, bad deflate, more than `maxBytes` once inflated, JSON that is not
/// `{v: 1, url: http(s) string, jsonld: [string, ...]}`, or no string blocks.
/// A non-string block is dropped, not fatal, as `SharedRecipePage` does for
/// Safari.
enum RecipeLink {

    static let prefix = "r1"
    static let maxBytes = 512 * 1024
    /// The host that marks a recipe link in Coach's own scheme. A log link is
    /// `dugcanliftcoach://import#1z…`; the two never share a host.
    static let host = "recipe"

    /// The bookmarklet's shared wording, used in every build.
    static let unreadableMessage =
        "That recipe link could not be read, so nothing was added. Open the recipe page and tap Send to Coach again."
    static let noRecipeMessage =
        "That page has no recipe Coach can read. Copy the recipe text and use Paste a recipe instead."

    /// Unwraps a recipe link, or the fragment on its own. Reads after the first
    /// `#` when there is one, as the reference does.
    static func decode(_ text: String) -> SharedRecipePage? {
        let fragment = text.firstIndex(of: "#").map { String(text[text.index(after: $0)...]) } ?? text
        guard fragment.hasPrefix(prefix) else { return nil }
        let data = fragment.dropFirst(prefix.count)
        guard !data.isEmpty, data.allSatisfy(isBase64URL),
              let bytes = base64URLDecoded(String(data)),
              let inflated = inflateRaw(bytes, limit: maxBytes)
        else { return nil }

        // Node decodes the bytes as UTF-8 with replacement before JSON.parse;
        // so does this, so an odd byte in a block is not a refusal here alone.
        let json = Data(String(decoding: inflated, as: UTF8.self).utf8)
        guard let doc = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              isOne(doc["v"]),
              let address = doc["url"] as? String,
              let jsonld = doc["jsonld"] as? [Any],
              address.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: address)
        else { return nil }
        let blocks = jsonld.compactMap { $0 as? String }
        guard !blocks.isEmpty else { return nil }
        return SharedRecipePage(url: url, blocks: blocks)
    }

    // MARK: - Pieces

    private static func isBase64URL(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// `v === 1` in JavaScript: the number one, never `true` or `"1"`.
    private static func isOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }

    /// Unpadded base64url to bytes. A length that leaves one character over
    /// cannot be base64 at all, and is refused rather than truncated.
    static func base64URLDecoded(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: return nil
        }
        return Data(base64Encoded: standard)
    }

    /// Raw deflate (RFC 1951) -- `COMPRESSION_ZLIB` is raw deflate, with no
    /// zlib header -- stopped as soon as the output passes `limit`, so a small
    /// link cannot inflate into a large allocation. Nil for a stream that is
    /// malformed or ends before its final block.
    static func inflateRaw(_ input: Data, limit: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()

        return input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                output.append(buffer, count: produced)
                if output.count > limit { return nil }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // Room left over with the whole input given means the
                    // decoder wants more than there is: a truncated stream.
                    if stream.pointee.dst_size > 0 { return nil }
                default:
                    return nil
                }
            }
        }
    }
}

/// Where a `dugcanliftcoach://` URL goes, decided by its host before anything
/// reads its fragment, so a log link and a recipe link can never be taken for
/// each other. `recipe` is the bookmarklet's; everything else is the log path
/// it has always been (`ShareLinkImporter`), which refuses what it cannot read.
enum CoachURLRoute: Equatable {
    /// A LIFT log link, for `ShareLinkImporter.importLink`.
    case log(String)
    /// A recipe to review, in the shape Safari's share extension queues.
    case recipe(PendingRecipeImports.Item)
    /// A recipe link that did not decode.
    case unreadableRecipe
    /// A recipe link that decoded, but holds no schema.org Recipe.
    case noRecipe

    init(_ url: URL) {
        guard url.scheme?.lowercased() == ShareLinkExtractor.urlScheme,
              url.host?.lowercased() == RecipeLink.host
        else { self = .log(url.absoluteString); return }
        guard let page = RecipeLink.decode(url.absoluteString) else { self = .unreadableRecipe; return }
        guard let found = page.firstRecipe() else { self = .noRecipe; return }
        self = .recipe(.init(block: found.block, pageURL: page.url.absoluteString))
    }
}

/// The ready `javascript:` bookmarklets, bundled byte for byte from
/// `dugcanlift-kit`'s `bookmarklet/bookmarklets.json` with its `.sha256`.
/// Never edited here: the kit builds them from `send-recipe.js`.
enum Bookmarklets {
    /// The `coachApp` target, which opens `dugcanliftcoach://recipe#r1…`.
    static func coachApp(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "bookmarklets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return all["coachApp"] as? String
    }
}
