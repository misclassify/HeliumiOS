import SwiftUI
import WebKit

// MARK: - Web view host

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        uiView.subviews.forEach { $0.removeFromSuperview() }
    }
}

// MARK: - Address field

struct AddressField: UIViewRepresentable {
    @Binding var text: String
    var onCommit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.placeholder = "Search or enter address"
        f.keyboardType = .webSearch
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.returnKeyType = .go
        f.clearButtonMode = .whileEditing
        f.delegate = context.coordinator
        f.text = text
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.async {
            f.becomeFirstResponder()
            f.selectAll(nil)
        }
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        if f.text != text { f.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        init(_ parent: AddressField) { self.parent = parent }
        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }
        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            parent.onCommit(f.text ?? "")
            return true
        }
    }
}

// MARK: - Start page

struct StartView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image("Logo")
                .resizable().scaledToFit()
                .frame(width: 84, height: 84)
            Text("Helium")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("The browser built around privacy, consent, and comfort.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 6) {
                Image(systemName: settings.blockTrackers ? "shield.checkered" : "shield.slash")
                Text(settings.blockTrackers ? "Tracker blocking on" : "Tracker blocking off")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Browser

struct BrowserView: View {
    @StateObject private var store = BrowserStore()
    @State private var showSwitcher = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if let tab = store.current {
                TabScreen(tab: tab, store: store, showSwitcher: $showSwitcher, showSettings: $showSettings)
                    .id(tab.id)
            } else {
                Color(.systemBackground)
            }
        }
        .fullScreenCover(isPresented: $showSwitcher) {
            TabSwitcher(store: store, isPresented: $showSwitcher)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .onOpenURL { url in
            // helium://open?url=https%3A%2F%2Fexample.com
            if url.scheme == "helium",
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let target = comps.queryItems?.first(where: { $0.name == "url" })?.value,
               let u = URL(string: target) {
                store.newTab(url: u, isPrivate: false)
            }
        }
    }
}

struct TabScreen: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @Binding var showSwitcher: Bool
    @Binding var showSettings: Bool

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if tab.url == nil {
                    StartView()
                } else {
                    WebViewHost(webView: tab.webView)
                }
                if tab.isLoading && tab.url != nil {
                    ProgressView(value: tab.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .background(tab.isPrivate ? Color(white: 0.12) : Color(.systemBackground))
        .preferredColorScheme(tab.isPrivate ? .dark : nil)
        .onAppear { tab.activate() }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if editing {
                    AddressField(text: $draft) { text in
                        editing = false
                        store.go(text)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Button("Cancel") { editing = false }
                } else {
                    addressPill
                }
            }
            if !editing { toolbar }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var addressPill: some View {
        Button {
            draft = tab.url?.absoluteString ?? ""
            editing = true
        } label: {
            HStack(spacing: 6) {
                if tab.isPrivate { Image(systemName: "eyeglasses").font(.footnote) }
                if tab.url?.scheme == "https" { Image(systemName: "lock.fill").font(.caption2) }
                Text(displayText)
                    .lineLimit(1)
                    .foregroundStyle(tab.url == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                if tab.url != nil {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote)
                        .padding(8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var displayText: String {
        guard let url = tab.url else { return "Search or enter address" }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Spacer()
            if let url = tab.url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task {
                    await tab.captureSnapshot()
                    showSwitcher = true
                }
            } label: {
                Image(systemName: "square.on.square")
                    .overlay(alignment: .topTrailing) {
                        Text("\(store.tabs.count)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(3)
                            .background(Circle().fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -8)
                    }
            }
            Spacer()
            menu
        }
        .font(.system(size: 19))
        .frame(height: 38)
    }

    private var menu: some View {
        Menu {
            Button { store.newTab(url: nil, isPrivate: false) } label: { Label("New Tab", systemImage: "plus") }
            Button { store.newTab(url: nil, isPrivate: true) } label: { Label("New Private Tab", systemImage: "eyeglasses") }
            Divider()
            if tab.url != nil {
                Button { tab.showFind() } label: { Label("Find on Page", systemImage: "magnifyingglass") }
                Button { tab.toggleDesktopMode() } label: {
                    Label(tab.desktopMode ? "Request Mobile Site" : "Request Desktop Site",
                          systemImage: tab.desktopMode ? "iphone" : "desktopcomputer")
                }
                Button { tab.goHome() } label: { Label("Close Page", systemImage: "house") }
                Divider()
            }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

// MARK: - Tab switcher

struct TabSwitcher: View {
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.tabs) { tab in
                        TabCard(tab: tab, isSelected: tab.id == store.selectedID,
                                onSelect: { store.select(tab); isPresented = false },
                                onClose: { store.close(tab) })
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Menu {
                    Button { store.newTab(url: nil, isPrivate: true); isPresented = false } label: {
                        Label("New Private Tab", systemImage: "eyeglasses")
                    }
                } label: { Image(systemName: "eyeglasses") }
                Spacer()
                Button {
                    store.newTab(url: nil, isPrivate: false)
                    isPresented = false
                } label: { Image(systemName: "plus") }
                Spacer()
                Button("Done") { isPresented = false }.fontWeight(.semibold)
            }
            .font(.system(size: 20))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct TabCard: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if tab.isPrivate { Image(systemName: "eyeglasses").font(.caption2) }
                    Text(tab.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                ZStack {
                    Color(.secondarySystemBackground)
                    if let img = tab.snapshot {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: tab.url == nil ? "plus.square.dashed" : "globe")
                            .font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 170)
                .clipped()
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var blocker = BlockerManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search engine", selection: $settings.engine) {
                        ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Type !g, !yt, !w, !gh and similar shortcuts before or after a query. They are resolved on your device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Toggle("Block ads & trackers", isOn: $settings.blockTrackers)
                    Toggle("Block third-party cookies", isOn: $settings.blockThirdPartyCookies)
                    Toggle("Upgrade to HTTPS", isOn: $settings.upgradeHTTPS)
                    Toggle("Strip tracking parameters", isOn: $settings.stripTrackingParams)
                    Toggle("Reduce fingerprinting", isOn: $settings.reduceFingerprinting)
                }

                Section {
                    ForEach(FilterList.allCases) { list in
                        Toggle(list.title, isOn: Binding(
                            get: { settings.isEnabled(list) },
                            set: { settings.setEnabled(list, $0) }))
                    }
                    Button {
                        Task { await BlockerManager.shared.rebuild(forceDownload: true) }
                    } label: {
                        HStack {
                            Text("Update filter lists now")
                            if blocker.isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(blocker.isWorking || !settings.blockTrackers)
                } header: {
                    Text("Filter lists")
                } footer: {
                    Text(blocker.status.isEmpty ? "Lists refresh weekly." : blocker.status)
                }

                Section("Data") {
                    Button("Clear browsing data", role: .destructive) { confirmClear = true }
                }

                Section("About") {
                    LabeledContent("Version", value: "0.22.2 (iOS port)")
                    LabeledContent("Engine", value: "WebKit")
                    Text("Unofficial, personal port inspired by Helium from imput. It uses Apple's WebKit engine, so Chromium-only features (extensions, Helium's Chromium patches) aren't available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear cookies, cache and site data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { store.clearBrowsingData() }
            }
        }
    }
}
