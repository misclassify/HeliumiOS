import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, brave, startpage, mojeek, google
    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .mojeek: return "Mojeek"
        case .google: return "Google"
        }
    }

    var template: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=%@"
        case .brave: return "https://search.brave.com/search?q=%@"
        case .startpage: return "https://www.startpage.com/do/search?q=%@"
        case .mojeek: return "https://www.mojeek.com/search?q=%@"
        case .google: return "https://www.google.com/search?q=%@"
        }
    }
}

/// Local !bang shortcuts. Resolved on-device, so nothing is sent to a third party.
enum Bangs {
    static let table: [String: String] = [
        "g": "https://www.google.com/search?q=%@",
        "ddg": "https://duckduckgo.com/?q=%@",
        "b": "https://search.brave.com/search?q=%@",
        "w": "https://en.wikipedia.org/wiki/Special:Search?search=%@",
        "yt": "https://www.youtube.com/results?search_query=%@",
        "gh": "https://github.com/search?q=%@",
        "r": "https://www.reddit.com/search/?q=%@",
        "a": "https://www.amazon.com/s?k=%@",
        "mdn": "https://developer.mozilla.org/en-US/search?q=%@",
        "so": "https://stackoverflow.com/search?q=%@",
        "npm": "https://www.npmjs.com/search?q=%@",
        "imdb": "https://www.imdb.com/find?q=%@",
        "maps": "https://www.openstreetmap.org/search?query=%@",
        "tr": "https://translate.google.com/?text=%@",
    ]
}

enum Address {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ q: String) -> String {
        q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
    }

    /// Turns whatever was typed into a URL: a real address, a !bang search, or a search query.
    static func resolve(_ input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        if let url = urlIfAddress(text) { return url }

        var words = text.split(separator: " ").map(String.init)
        if let first = words.first, first.hasPrefix("!"),
           let tpl = Bangs.table[String(first.dropFirst()).lowercased()] {
            words.removeFirst()
            return URL(string: String(format: tpl, encode(words.joined(separator: " "))))
        }
        if let last = words.last, last.hasPrefix("!"), words.count > 1,
           let tpl = Bangs.table[String(last.dropFirst()).lowercased()] {
            words.removeLast()
            return URL(string: String(format: tpl, encode(words.joined(separator: " "))))
        }
        return URL(string: String(format: engine.template, encode(text)))
    }

    private static func urlIfAddress(_ text: String) -> URL? {
        if text.contains(" ") { return nil }
        if text.contains("://") {
            if let u = URL(string: text), u.host != nil || u.scheme == "file" { return u }
            return nil
        }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("javascript:") { return nil }
        let hostPart = lower.split(separator: "/").first.map(String.init) ?? lower
        let hostNoPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isLocal = hostNoPort == "localhost"
        let looksLikeDomain = hostNoPort.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$",
                                               options: .regularExpression) != nil
        guard isLocal || looksLikeDomain else { return nil }
        let scheme = (isLocal || hostNoPort.range(of: "^[0-9.]+$", options: .regularExpression) != nil) ? "http" : "https"
        return URL(string: "\(scheme)://\(text)")
    }
}
