import Foundation
import WebKit

enum FilterList: String, CaseIterable, Identifiable {
    case ublock, easyPrivacy, easyList, peterLowe
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ublock: return "uBlock Origin filters"
        case .easyPrivacy: return "EasyPrivacy"
        case .easyList: return "EasyList"
        case .peterLowe: return "Peter Lowe's ad servers"
        }
    }

    var url: URL {
        switch self {
        case .ublock: return URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt")!
        case .easyPrivacy: return URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
        case .easyList: return URL(string: "https://easylist.to/easylist/easylist.txt")!
        case .peterLowe: return URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!
        }
    }

    var defaultOn: Bool { self == .ublock || self == .easyPrivacy }
}

enum ContentBlocker {
    static let builtinDomains: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "analytics.facebook.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "hotjar.com", "hotjar.io",
        "mixpanel.com", "segment.io", "amplitude.com", "fullstory.com", "mouseflow.com", "crazyegg.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "adnxs.com", "rubiconproject.com",
        "pubmatic.com", "openx.net", "casalemedia.com", "adsrvr.org", "bluekai.com", "krxd.net",
        "demdex.net", "omtrdc.net", "2o7.net", "moatads.com", "doubleverify.com", "adsafeprotected.com",
        "amazon-adsystem.com", "ads-twitter.com", "analytics.twitter.com", "ads.linkedin.com",
        "analytics.tiktok.com", "clarity.ms", "bat.bing.com", "chartbeat.com", "parsely.com",
        "mathtag.com", "bidswitch.net", "smartadserver.com", "yieldmo.com", "sharethrough.com",
        "33across.com", "tapad.com", "everesttech.net", "agkn.com", "rlcdn.com", "liadm.com",
        "id5-sync.com", "permutive.com", "nr-data.net", "adform.net", "advertising.com",
        "serving-sys.com", "media.net", "zedo.com", "adition.com", "mc.yandex.ru",
    ]

    private static func domainFilter(_ host: String) -> String {
        "^https?://([^/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
    }

    private static func encode(_ rules: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func builtinJSON() -> String {
        encode(builtinDomains.map {
            ["trigger": ["url-filter": domainFilter($0)], "action": ["type": "block"]]
        })
    }

    static let cookieJSON = """
    [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
    """

    /// Converts the simple domain-anchored rules (`||host^` with optional `$third-party`, `$script`, ...)
    /// of an Adblock Plus / uBlock style list into WebKit content-blocker JSON.
    /// Cosmetic filters, exceptions and complex patterns are skipped.
    static func convert(_ text: String, limit: Int = 90_000) -> (json: String, count: Int) {
        let typeMap: [String: String] = [
            "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
            "media": "media", "font": "font", "xmlhttprequest": "raw", "xhr": "raw",
        ]
        var rules: [[String: Any]] = []
        var seen = Set<String>()

        outer: for raw in text.split(whereSeparator: \.isNewline) {
            if rules.count >= limit { break }
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("||") else { continue }
            line.removeFirst(2)

            var options: [String] = []
            if let dollar = line.firstIndex(of: "$") {
                options = line[line.index(after: dollar)...].split(separator: ",").map { String($0).lowercased() }
                line = String(line[..<dollar])
            }
            guard line.hasSuffix("^") else { continue }
            line.removeLast()
            let host = line.lowercased()
            guard host.range(of: "^[a-z0-9][a-z0-9.-]*\\.[a-z0-9-]{2,}$", options: .regularExpression) != nil else { continue }

            var trigger: [String: Any] = ["url-filter": domainFilter(host)]
            var types: [String] = []
            for opt in options {
                switch opt {
                case "third-party", "3p": trigger["load-type"] = ["third-party"]
                case "important": break
                default:
                    if let t = typeMap[opt] { types.append(t) } else { continue outer }
                }
            }
            if !types.isEmpty { trigger["resource-type"] = types }

            let key = host + "|" + options.sorted().joined(separator: ",")
            if !seen.insert(key).inserted { continue }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        return (rules.isEmpty ? "[]" : encode(rules), rules.count)
    }
}

/// Compiles and caches WebKit content rule lists, and tells tabs which ones to use.
final class BlockerManager: ObservableObject {
    static let shared = BlockerManager()

    @Published private(set) var lists: [WKContentRuleList] = []
    @Published private(set) var status: String = ""
    @Published private(set) var isWorking = false

    private let lastUpdateKey = "filterListsLastUpdate"

    @MainActor
    func rebuild(forceDownload: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        let settings = AppSettings.shared

        var force = forceDownload
        if let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date,
           Date().timeIntervalSince(last) > 7 * 24 * 3600 {
            force = true
        }

        var result: [WKContentRuleList] = []
        var notes: [String] = []

        if settings.blockTrackers {
            if let l = await compile(id: "helium-builtin-v1", json: ContentBlocker.builtinJSON()) { result.append(l) }
            for list in FilterList.allCases where settings.isEnabled(list) {
                status = "Loading \(list.title)…"
                if let (l, note) = await loadList(list, force: force) {
                    result.append(l)
                    if let note { notes.append(note) }
                } else {
                    notes.append("\(list.title): failed")
                }
            }
            if force { UserDefaults.standard.set(Date(), forKey: lastUpdateKey) }
        }
        if settings.blockThirdPartyCookies,
           let l = await compile(id: "helium-3p-cookies-v1", json: ContentBlocker.cookieJSON) {
            result.append(l)
        }

        lists = result
        status = notes.isEmpty ? "Up to date" : notes.joined(separator: " · ")
    }

    @MainActor
    private func compile(id: String, json: String) async -> WKContentRuleList? {
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        if let existing = try? await store.lookUpContentRuleList(forIdentifier: id) { return existing }
        return try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
    }

    @MainActor
    private func loadList(_ list: FilterList, force: Bool) async -> (WKContentRuleList, String?)? {
        let id = "helium-list-\(list.rawValue)-v1"
        let store: WKContentRuleListStore = WKContentRuleListStore.default()
        if !force, let existing = try? await store.lookUpContentRuleList(forIdentifier: id) {
            return (existing, nil)
        }
        var request = URLRequest(url: list.url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            // Keep using whatever was compiled before.
            if let existing = try? await store.lookUpContentRuleList(forIdentifier: id) { return (existing, nil) }
            return nil
        }
        let (json, count) = ContentBlocker.convert(text)
        guard count > 0 else { return nil }
        try? await store.removeContentRuleList(forIdentifier: id)
        guard let compiled = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else { return nil }
        return (compiled, "\(list.title): \(count) rules")
    }
}
