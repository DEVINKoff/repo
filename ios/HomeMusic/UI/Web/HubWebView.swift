import SwiftUI
import UIKit
import WebKit

/// A Hub page inside the app (the Android app's `HubWebHolder`): the PWA opens as `/?embedded=1#/route`, so it draws
/// no tab bar of its own and plays through the app's player. The bridge `window.HomeMusicAndroid` is the same as the
/// Android app's (web/src/lib/player.ts): `play`, `playQueue`, `playWave`, `pauseNative`, `webPlayer`, `shareText`.
struct HubWebScreen: View {
    let path: String
    let title: String
    @State private var loading = true

    var body: some View {
        HubWebView(path: path, loading: $loading)
            .ignoresSafeArea(edges: .bottom)
            .overlay { if loading { ProgressView() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct HubWebView: UIViewRepresentable {
    let path: String
    @Binding var loading: Bool
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "hm")
        config.userContentController = controller
        config.applicationNameForUserAgent = "HomeMusicIOS/\(AppInfo.version)"

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.allowsBackForwardNavigationGestures = true
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web

        Task { @MainActor in
            await Self.syncCookies(into: web.configuration.websiteDataStore.httpCookieStore)
            guard let base = HubClient.shared.baseURL,
                  let url = URL(string: base.absoluteString + "/?embedded=1#" + path) else { return }
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.applyTheme(light: scheme == .light)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "hm")
    }

    /// The `hm_session` cookie of the native client goes to the page (one sign-in for both).
    @MainActor
    static func syncCookies(into store: WKHTTPCookieStore) async {
        for c in HubClient.shared.cookies { await store.setCookie(c) }
    }

    private static let bridge = """
    (function () {
      if (window.HomeMusicAndroid) return;
      var post = function (fn, args) {
        try { window.webkit.messageHandlers.hm.postMessage({ fn: fn, args: args }); } catch (e) {}
      };
      window.HomeMusicAndroid = {
        play: function (ids, index) { post('play', [String(ids), Number(index) || 0]); },
        playQueue: function (items, index) { post('playQueue', [String(items), Number(index) || 0]); },
        playWave: function (wave) { post('playWave', [String(wave)]); },
        pauseNative: function () { post('pauseNative', []); },
        webPlayer: function (visible) { post('webPlayer', [!!visible]); },
        shareText: function (text) { post('shareText', [String(text)]); }
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: HubWebView
        weak var web: WKWebView?
        private var lastLight: Bool?

        init(_ parent: HubWebView) { self.parent = parent }

        @MainActor @objc func reload(_ sender: UIRefreshControl) {
            web?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
        }

        @MainActor func applyTheme(light: Bool, force: Bool = false) {
            guard force || lastLight != light else { return }
            lastLight = light
            web?.evaluateJavaScript("window.hmApplyTheme && window.hmApplyTheme(\(light), null)")
        }

        // MARK: Bridge

        private struct Item: Decodable {
            var songId: String?
            var ref: String?
            var title: String?
            var artist: String?
            var album: String?
            var coverUrl: String?
            var durationS: Double?
            var context: String?
            var launchId: String?
            var launchOrigin: String?
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let fn = body["fn"] as? String else { return }
            let args = body["args"] as? [Any] ?? []
            MainActor.assumeIsolated { handle(fn, args) }
        }

        @MainActor
        private func handle(_ fn: String, _ args: [Any]) {
            let player = Player.shared
            func string(_ i: Int) -> String? { args.indices.contains(i) ? args[i] as? String : nil }
            func int(_ i: Int) -> Int { args.indices.contains(i) ? (args[i] as? NSNumber)?.intValue ?? 0 : 0 }
            switch fn {
            case "play":
                // library songs by their Navidrome ids (the Hub names them when they start)
                guard let raw = string(0), let ids = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String], !ids.isEmpty else { return }
                let list = ids.map { QueueTrack(ref: "nd:\($0)", ndSongId: $0, title: "", artist: "", coverUrl: "/api/nd/cover/mf-\($0)?size=600") }
                player.startFresh(list, at: min(max(0, int(1)), list.count - 1), context: "other")
            case "playQueue":
                guard let raw = string(0), let items = try? HubClient.shared.decodeValue([Item].self, from: Data(raw.utf8)), !items.isEmpty else { return }
                let list: [QueueTrack] = items.compactMap { it in
                    if let id = it.songId { return QueueTrack(ref: "nd:\(id)", ndSongId: id, title: it.title ?? "", artist: it.artist ?? "", coverUrl: "/api/nd/cover/mf-\(id)?size=600") }
                    guard let ref = it.ref else { return nil }
                    return QueueTrack(ref: ref, title: it.title ?? "", artist: it.artist ?? "", coverUrl: it.coverUrl, album: it.album, durationS: it.durationS)
                }
                guard !list.isEmpty else { return }
                let first = items.first
                player.startFresh(list, at: min(max(0, int(1)), list.count - 1), context: first?.context ?? "other",
                                  origin: first?.launchOrigin, launchId: first?.launchId)
            case "playWave":
                guard let raw = string(0), let w = try? HubClient.shared.decodeValue(WaveOut.self, from: Data(raw.utf8)) else { return }
                Wave.shared.play(w)
            case "pauseNative":
                player.pause()
            case "shareText":
                guard let text = string(0) else { return }
                let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                UIApplication.shared.topController?.present(vc, animated: true)
            default:
                break
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            let light = parent.scheme == .light
            MainActor.assumeIsolated { applyTheme(light: light, force: true) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            let message = error.localizedDescription
            MainActor.assumeIsolated { Toasts.error("Страница Хаба не открылась: \(message)") }
        }

        /// Pages of the Hub stay here; anything else (a source's page, Google) opens in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, let base = HubClient.shared.baseURL else { return .allow }
            if url.host == base.host && url.port == base.port { return .allow }
            if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
            _ = await UIApplication.shared.open(url)
            return .cancel
        }

        /// `target=_blank` links.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { MainActor.assumeIsolated { UIApplication.shared.open(url) } }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                MainActor.assumeIsolated {
                    let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "OK", style: .default) { _ in cont.resume() })
                    if let top = UIApplication.shared.topController { top.present(a, animated: true) } else { cont.resume() }
                }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                MainActor.assumeIsolated {
                    let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in cont.resume(returning: false) })
                    a.addAction(UIAlertAction(title: "OK", style: .default) { _ in cont.resume(returning: true) })
                    if let top = UIApplication.shared.topController { top.present(a, animated: true) } else { cont.resume(returning: false) }
                }
            }
        }
    }
}

extension UIApplication {
    var topController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
