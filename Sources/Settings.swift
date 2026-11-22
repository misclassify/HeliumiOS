import SwiftUI
import Combine

/// User-facing options, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var engine: SearchEngine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    @Published var blockTrackers: Bool { didSet { d.set(blockTrackers, forKey: "blockTrackers") } }
    @Published var blockThirdPartyCookies: Bool { didSet { d.set(blockThirdPartyCookies, forKey: "blockThirdPartyCookies") } }
    @Published var upgradeHTTPS: Bool { didSet { d.set(upgradeHTTPS, forKey: "upgradeHTTPS") } }
    @Published var stripTrackingParams: Bool { didSet { d.set(stripTrackingParams, forKey: "stripTrackingParams") } }
    @Published var reduceFingerprinting: Bool { didSet { d.set(reduceFingerprinting, forKey: "reduceFingerprinting") } }
    @Published var enabledLists: Set<String> { didSet { d.set(Array(enabledLists), forKey: "enabledLists") } }

    private init() {
        func bool(_ key: String, _ def: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
        }
        engine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .duckDuckGo
        blockTrackers = bool("blockTrackers", true)
        blockThirdPartyCookies = bool("blockThirdPartyCookies", true)
        upgradeHTTPS = bool("upgradeHTTPS", true)
        stripTrackingParams = bool("stripTrackingParams", true)
        reduceFingerprinting = bool("reduceFingerprinting", true)
        if let arr = UserDefaults.standard.array(forKey: "enabledLists") as? [String] {
            enabledLists = Set(arr)
        } else {
            enabledLists = Set(FilterList.allCases.filter { $0.defaultOn }.map { $0.rawValue })
        }
    }

    func isEnabled(_ list: FilterList) -> Bool { enabledLists.contains(list.rawValue) }

    func setEnabled(_ list: FilterList, _ on: Bool) {
        if on { enabledLists.insert(list.rawValue) } else { enabledLists.remove(list.rawValue) }
    }
}
