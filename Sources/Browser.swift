import SwiftUI
import WebKit
import Combine

extension UIApplication {
    static var topViewController: UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

// MARK: - Tab

@MainActor final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool

    @Published var title: String
    @Published var url: URL?
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var desktopMode = false
    @Published var snapshot: UIImage?

    let webView: WKWebView
    private weak var store: BrowserStore?
    private var observers: [NSKeyValueObservation] = []
    private var didLoad = false
    private var upgradedFrom: URL?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(url: URL?, title: String?, isPrivate: Bool, store: BrowserStore) {
        self.isPrivate = isPrivate
        self.store = store
        self.url = url
        self.title = title ?? "New Tab"

        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? store.privateDataStore : WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        webView.navigationDelegate = self
        webView.uiDelegate = self

        func watch<V>(_ keyPath: KeyPath<WKWebView, V>) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.syncFromWebView() }
            }
        }
        observers = [
            watch(\.title), watch(\.url), watch(\.estimatedProgress),
            watch(\.canGoBack), watch(\.canGoForward), watch(\.isLoading),
        ]
        applyProtections()
    }

    func applyProtections() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        for list in BlockerManager.shared.lists { ucc.add(list) }
        ucc.removeAllUserScripts()
        if AppSettings.shared.reduceFingerprinting {
            ucc.addUserScript(WKUserScript(source: Protections.fingerprintScript,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    private func syncFromWebView() {
        if let u = webView.url, u.absoluteString != "about:blank" { url = u }
        if let t = webView.title, !t.isEmpty { title = t } else if let host = webView.url?.host { title = host }
        progress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        store?.persistSoon()
    }

    /// Loads a restored tab the first time it is shown.
    func activate() {
        guard !didLoad, webView.url == nil, let u = url else { return }
        didLoad = true
        webView.load(URLRequest(url: u))
    }

    func load(_ u: URL) {
        didLoad = true
        url = u
        webView.load(URLRequest(url: u))
    }

    func goHome() {
        webView.stopLoading()
        url = nil
        title = "New Tab"
        didLoad = false
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        webView.reload()
    }

    func captureSnapshot() async {
        guard url != nil else { snapshot = nil; return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 400
        if let image = try? await webView.takeSnapshot(configuration: cfg) { snapshot = image }
    }

    func showFind() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    private func errorPage(for failing: URL?, error: Error) -> String {
        let link = failing?.absoluteString ?? ""
        let safeLink = link.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        let msg = error.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,sans-serif;text-align:center;margin:0;padding:96px 24px;color:#222;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#111}}
        h2{font-weight:600}p{opacity:.7;word-break:break-all}
        a{display:inline-block;margin-top:24px;padding:12px 24px;border-radius:12px;background:#0a84ff;color:#fff;text-decoration:none}</style></head>
        <body><h2>Can’t open this page</h2><p>\(msg)</p><p>\(safeLink)</p><a href="\(safeLink)">Try again</a></body></html>
        """
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .recommended

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let settings = AppSettings.shared

        // Hand non-web schemes (tel:, mailto:, App Store links, ...) to the system.
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if isMain, !webSchemes.contains(scheme) {
            decisionHandler(.cancel, preferences)
            UIApplication.shared.open(url)
            return
        }

        if isMain, scheme == "http", settings.upgradeHTTPS, let host = url.host,
           !(store?.httpExceptions.contains(host) ?? false),
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            if comps.port == 80 { comps.port = nil }
            if let upgraded = comps.url {
                upgradedFrom = url
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: upgraded))
                return
            }
        }

        if isMain, settings.stripTrackingParams, navigationAction.request.httpMethod == "GET" {
            let cleaned = Protections.stripTracking(url)
            if cleaned != url {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: cleaned))
                return
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let current = webView.url, let from = upgradedFrom, current.host == from.host { upgradedFrom = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted (downloads)

        // HTTPS upgrade failed: remember the host and fall back to the original http:// address.
        if let original = upgradedFrom {
            upgradedFrom = nil
            if let host = original.host { store?.httpExceptions.insert(host) }
            webView.load(URLRequest(url: original))
            return
        }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        webView.loadHTMLString(errorPage(for: failing, error: error), baseURL: failing)
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url {
            store?.newTab(url: u, isPrivate: isPrivate)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, orElse: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, orElse: { completionHandler(nil) })
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    private func present(_ vc: UIViewController, orElse fallback: () -> Void) {
        if let top = UIApplication.topViewController { top.present(vc, animated: true) } else { fallback() }
    }
}

// MARK: - Downloads

extension Tab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)),
              let top = UIApplication.topViewController else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 1, height: 1)
        top.present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }
}

// MARK: - Store

@MainActor final class BrowserStore: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?

    var privateDataStore = WKWebsiteDataStore.nonPersistent()
    var httpExceptions = Set<String>()

    private var cancellables = Set<AnyCancellable>()
    private var persistTask: Task<Void, Never>?

    private struct SavedTab: Codable { var url: String?; var title: String }
    private struct SavedState: Codable { var tabs: [SavedTab]; var selected: Int }

    var current: Tab? { tabs.first { $0.id == selectedID } }

    init() {
        restore()
        if tabs.isEmpty { newTab(url: nil, isPrivate: false) }
        current?.activate()

        BlockerManager.shared.$lists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tabs.forEach { $0.applyProtections() } }
            .store(in: &cancellables)

        AppSettings.shared.objectWillChange
            .debounce(for: .seconds(0.6), scheduler: DispatchQueue.main)
            .sink { _ in Task { await BlockerManager.shared.rebuild() } }
            .store(in: &cancellables)

        Task { await BlockerManager.shared.rebuild() }
    }

    @discardableResult
    func newTab(url: URL?, isPrivate: Bool, select: Bool = true) -> Tab {
        let tab = Tab(url: url, title: nil, isPrivate: isPrivate, store: self)
        tabs.append(tab)
        if let url { tab.load(url) }
        if select { selectedID = tab.id }
        persistSoon()
        return tab
    }

    func select(_ tab: Tab) {
        selectedID = tab.id
        tab.activate()
        persistSoon()
    }

    func close(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if !tabs.contains(where: { $0.isPrivate }) { privateDataStore = WKWebsiteDataStore.nonPersistent() }
        if tabs.isEmpty {
            newTab(url: nil, isPrivate: false)
        } else if selectedID == tab.id {
            let next = tabs[min(idx, tabs.count - 1)]
            select(next)
        }
        persistSoon()
    }

    func go(_ input: String) {
        guard let tab = current, let url = Address.resolve(input, engine: AppSettings.shared.engine) else { return }
        tab.load(url)
    }

    func clearBrowsingData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    // Persistence of open (non-private) tabs

    func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            self?.persist()
        }
    }

    private func persist() {
        let normal = tabs.filter { !$0.isPrivate }
        let selectedIdx = normal.firstIndex { $0.id == selectedID } ?? 0
        let state = SavedState(tabs: normal.map { SavedTab(url: $0.url?.absoluteString, title: $0.title) }, selected: selectedIdx)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "savedTabs") }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: "savedTabs"),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        for saved in state.tabs {
            let url = saved.url.flatMap { URL(string: $0) }
            tabs.append(Tab(url: url, title: saved.title, isPrivate: false, store: self))
        }
        if !tabs.isEmpty { selectedID = tabs[min(max(state.selected, 0), tabs.count - 1)].id }
    }
}
