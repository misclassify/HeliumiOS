import Foundation

enum Protections {
    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid",
        "yclid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "wickedid", "twclid", "ttclid",
        "li_fat_id", "s_cid",
    ]

    /// Removes well-known tracking query parameters. Returns the same URL if nothing was removed.
    static func stripTracking(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
        if kept.count == items.count { return url }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url ?? url
    }

    /// Light fingerprint-surface reduction + Global Privacy Control signal.
    static let fingerprintScript = """
    (function () {
      var def = function (o, k, v) {
        try { Object.defineProperty(o, k, { get: function () { return v; }, configurable: true }); } catch (e) {}
      };
      try {
        def(Navigator.prototype, 'hardwareConcurrency', 4);
        def(Navigator.prototype, 'deviceMemory', 8);
        def(Navigator.prototype, 'globalPrivacyControl', true);
        if (navigator.getBattery) { def(Navigator.prototype, 'getBattery', undefined); }
      } catch (e) {}
    })();
    """
}
