import Foundation
import LiftCore

/// Finds a client's LIFT log fragment in whatever reached Coach: a pasted
/// string, a URL shared from Safari or Messages, a note or an email body with
/// the link somewhere inside it, or Coach's own `dugcanliftcoach://` URL.
///
/// Compiled into both the app and the share extension, so it imports nothing
/// but Foundation and `LiftCore` -- no SwiftData, no views. Paste a Link, the
/// share extension and `onOpenURL` all go through `payload(in:)`, so a link
/// that imports one way imports every way, and one that fails, fails alike.
///
/// The rule, in order:
/// 1. The first LIFT Coach link anywhere in the text wins. That is
///    `https://www.dugcanlift.com/coach/#1z...` (scheme optional, `www.`
///    optional, host case-insensitive) or `dugcanliftcoach://import#1z...`.
///    Text around it is ignored, including a `#` in the prose before it
///    ("Week #3: ..."), which is why this does not simply split on the last
///    `#` as Coach Android's paste field does.
/// 2. Otherwise the text itself may be a bare fragment, as copied on its own:
///    trimmed, an optional leading `#`, then `1z`/`1u`.
/// 3. Anything else is not a LIFT link -- including another site's URL that
///    happens to carry a `#1z...` fragment.
///
/// In both accepted cases the fragment ends at the first character outside
/// base64url, so a mail client's `<...>` or a sentence's full stop is dropped.
/// Whether the fragment actually decodes is `ShareLinkCodec`'s call, not this
/// function's.
enum ShareLinkExtractor {

    /// Coach's own URL scheme, declared in project.yml's `CFBundleURLTypes`.
    static let urlScheme = "dugcanliftcoach"

    static func fragment(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = linkPattern.firstMatch(in: text, range: range),
           let fragmentRange = Range(match.range(at: 1), in: text) {
            return String(text[fragmentRange])
        }

        var bare = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if bare.hasPrefix("#") { bare = bare.dropFirst() }
        guard bare.hasPrefix("1z") || bare.hasPrefix("1u") else { return nil }
        let fragment = bare.prefix { isBase64URLCharacter($0) }
        return fragment.count > 2 ? String(fragment) : nil
    }

    /// Extracts and decodes in one step -- the only entry point views use.
    static func payload(in text: String) throws -> ShareLinkPayload {
        guard let fragment = fragment(in: text) else { throw ShareLinkError.malformedFragment }
        return try ShareLinkCodec.decode(fragment: fragment)
    }

    /// "Jordan Reyes's log · 56 days" -- what the share extension asks the
    /// coach to confirm, and what the app reports after importing.
    static func summary(of payload: ShareLinkPayload) -> String {
        let name = payload.c.n.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = name.isEmpty ? "A client's" : "\(name)'s"
        let days = payload.d.count
        return "\(owner) log · \(days) day\(days == 1 ? "" : "s")"
    }

    /// True for the web Coach's address with no log fragment. The web app
    /// removes the fragment from the address bar as soon as it has read it
    /// (`history.replaceState` in coach/app.js), so a link opened in Safari and
    /// then shared from there arrives like this -- worth its own explanation,
    /// since the coach did share "the link".
    static func isCoachPageWithoutLog(_ text: String) -> Bool {
        fragment(in: text) == nil
            && coachPagePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The URL that opens Coach and imports `fragment`.
    static func openURL(for fragment: String) -> URL? {
        URL(string: "\(urlScheme)://import#\(fragment)")
    }

    // `(?i:...)` scopes case-insensitivity to the host and scheme: the codec
    // letter after `1` is case-sensitive, and `1Z` is not a codec. The
    // lookbehind stops `notdugcanlift.com`, or the real host appearing in
    // another site's path or userinfo, from counting as the real host.
    private static let linkPattern = try! NSRegularExpression(pattern:
        #"(?i:(?<![A-Za-z0-9./@-])(?:(?:https?://)?(?:www\.)?dugcanlift\.com/coach/?(?:index\.html)?|dugcanliftcoach:(?://)?[^\s#]*))#(1[zu][A-Za-z0-9_-]+)"#)

    private static let coachPagePattern = try! NSRegularExpression(pattern:
        #"^\s*(?i:(?:https?://)?(?:www\.)?dugcanlift\.com/coach/?(?:index\.html)?)#?\s*$"#)

    private static func isBase64URLCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }
}
