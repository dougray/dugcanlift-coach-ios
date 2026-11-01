import XCTest

/// What Coach may ask iOS for, pinned against the public privacy policy.
///
/// `www.dugcanlift.com/coach/privacy/` (`dugcanlift-site/coach-privacy.md`)
/// tells coaches what the iPhone app touches: "Network requests, by platform"
/// > "iPhone" (no requests, no map service, a built-in food database) and
/// "Where Coach stores things" > "iPhone" (the app's own container, no iCloud
/// sync). Coach's iPhone answer to an Android permission list is three things,
/// and this pins each one to an explicit list:
///
/// - every `NS…UsageDescription` key -- iOS refuses a protected resource
///   (camera, location, Health, contacts…) to an app without its purpose
///   string, so the set of these keys *is* the set Coach can ask for;
/// - `UIBackgroundModes`;
/// - every entitlement, which is where capabilities like App Groups, HealthKit,
///   iCloud or Associated Domains live.
///
/// **A change here fails the build until someone has updated the privacy page
/// to match.** That page is public copy and Doug reviews it, so update
/// `coach-privacy.md` first, then the list below -- never the list alone.
///
/// Usage keys and background modes are read from the *built* bundles at
/// runtime (the test host is Coach.app, so `Bundle.main` is what ships, and its
/// extensions are in `PlugIns/`), which catches a key however it got there: an
/// `info.properties` entry in project.yml, an `INFOPLIST_KEY_` build setting,
/// or a hand-edited plist. Entitlements are read from the files xcodegen
/// renders from project.yml (`make test` runs `xcodegen generate` first), since
/// a simulator build does not expose its signed entitlements to a test.
final class PermissionPinTests: XCTestCase {

    struct BundlePin: Equatable {
        var usageDescriptions: Set<String> = []
        var backgroundModes: [String] = []
    }

    /// Coach.app and each extension, by bundle file name. Neither asks for any
    /// protected resource: a coach pastes or shares a link, and nothing else.
    static let bundles: [String: BundlePin] = [
        "Coach.app": BundlePin(),
        // The share extension ("Coach" in the share sheet) reads only what the
        // share sheet hands it.
        "PlugIns/CoachShare.appex": BundlePin(),
    ]

    /// project.yml's `entitlements.properties`, file by file. The App Group is
    /// the share extension's hand-off to the app: it is storage on the device
    /// shared by Coach's own two bundles, not a sync of any kind.
    static let entitlements: [String: NSDictionary] = [
        "Coach.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.coach"],
        ],
        "CoachShare.entitlements": [
            "com.apple.security.application-groups": ["group.com.dugcanlift.coach"],
        ],
    ]

    static let page = "dugcanlift-site/coach-privacy.md, \"Network requests, by platform\" > \"iPhone\" and \"Where Coach stores things\""

    static func pin(ofInfo info: [String: Any]) -> BundlePin {
        BundlePin(usageDescriptions: Set(info.keys.filter { $0.hasPrefix("NS") && $0.contains("UsageDescription") }),
                  backgroundModes: info["UIBackgroundModes"] as? [String] ?? [])
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheHostIsTheShippedApp() {
        // Everything below reads Bundle.main as Coach.app; a test bundle that
        // stopped being hosted would quietly read its own Info.plist instead.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.dugcanlift.coach")
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "Coach.app")
    }

    func testEveryBuiltBundleAsksForExactlyWhatThePrivacyPageSays() throws {
        let app = Bundle.main.bundleURL
        let plugIns = (try? FileManager.default.contentsOfDirectory(
            at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []
        let found = ["Coach.app"]
            + plugIns.filter { $0.pathExtension == "appex" }.map { "PlugIns/\($0.lastPathComponent)" }
            + ((try? FileManager.default.contentsOfDirectory(
                at: app.appendingPathComponent("Watch"), includingPropertiesForKeys: nil)) ?? [])
                .map { "Watch/\($0.lastPathComponent)" }
        // A new extension or an embedded watch app is a new bundle with its own
        // Info.plist, so it must be pinned before it can ship.
        XCTAssertEqual(Set(found), Set(Self.bundles.keys), "the set of shipped bundles changed -- pin it, and check \(Self.page)")

        for name in found {
            let url = name == "Coach.app" ? app : app.appendingPathComponent(name)
            let info = try XCTUnwrap(Bundle(url: url)?.infoDictionary, "no Info.plist in \(name)")
            XCTAssertEqual(Self.pin(ofInfo: info), Self.bundles[name],
                           "\(name) asks iOS for something new. Update \(Self.page) first, then this pin.")
        }
    }

    func testEntitlementsAreExactlyWhatThePrivacyPageSays() throws {
        let config = Self.repoRoot.appendingPathComponent("Config")
        let files = try FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "entitlements" }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(Self.entitlements.keys),
                       "the set of entitlements files changed (did `xcodegen generate` run?) -- pin it, and check \(Self.page)")
        for file in files {
            let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
            let actual = try XCTUnwrap(parsed as? NSDictionary, "\(file.lastPathComponent) is not a dictionary")
            XCTAssertEqual(actual, Self.entitlements[file.lastPathComponent],
                           "\(file.lastPathComponent) changed. Update \(Self.page) first, then this pin.")
        }
    }

    /// project.yml names every entitlements file it renders, so a target that
    /// points somewhere outside Config/ cannot dodge the check above.
    func testProjectYmlNamesOnlyThePinnedEntitlementsFiles() throws {
        let yml = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let named = yml.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasSuffix(".entitlements"),
                  let path = trimmed.split(separator: ":", maxSplits: 1).last else { return nil }
            return path.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(Set(named), Set(Self.entitlements.keys.map { "Config/\($0)" }))
    }

    func testTheReaderSeesAUsageKey() {
        // The filter above must actually find one, or every pin passes for nothing.
        let pin = Self.pin(ofInfo: ["NSCameraUsageDescription": "x", "NSLocationTemporaryUsageDescriptionDictionary": [:],
                                    "NSSupportsLiveActivities": true, "UIBackgroundModes": ["location"]])
        XCTAssertEqual(pin, BundlePin(usageDescriptions: ["NSCameraUsageDescription", "NSLocationTemporaryUsageDescriptionDictionary"],
                                      backgroundModes: ["location"]))
    }
}
